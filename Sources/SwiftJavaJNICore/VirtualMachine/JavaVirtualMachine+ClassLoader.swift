//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift.org project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift.org project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Global references and method IDs needed to use the application class loader
/// from any thread. Created once per loader and kept for the life of the process.
final class ApplicationClassLoader: @unchecked Sendable {
  let loader: jobject
  let threadClass: jclass
  let currentThread: jmethodID
  let setContextClassLoader: jmethodID
  let loadClass: jmethodID

  init?(loader localLoader: jobject, in environment: JNIEnvironment) {
    let interface = environment.interface
    guard
      let threadClass = interface.FindClass(environment, "java/lang/Thread"),
      let currentThread = interface.GetStaticMethodID(
        environment,
        threadClass,
        "currentThread",
        "()Ljava/lang/Thread;"
      ),
      let setContextClassLoader = interface.GetMethodID(
        environment,
        threadClass,
        "setContextClassLoader",
        "(Ljava/lang/ClassLoader;)V"
      ),
      let classLoaderClass = interface.FindClass(environment, "java/lang/ClassLoader"),
      let loadClass = interface.GetMethodID(
        environment,
        classLoaderClass,
        "loadClass",
        "(Ljava/lang/String;)Ljava/lang/Class;"
      )
    else {
      interface.ExceptionClear(environment)
      return nil
    }
    defer {
      interface.DeleteLocalRef(environment, threadClass)
      interface.DeleteLocalRef(environment, classLoaderClass)
    }
    self.loader = interface.NewGlobalRef(environment, localLoader)!
    self.threadClass = interface.NewGlobalRef(environment, threadClass)!
    self.currentThread = currentThread
    self.setContextClassLoader = setContextClassLoader
    self.loadClass = loadClass
  }
}

extension JavaVirtualMachine {
  /// Registers the JVM that is loading this library. Call it from `JNI_OnLoad`.
  ///
  /// This adopts `javaVM` as the shared instance (see ``current``) and captures
  /// the loading thread's context class loader as the ``applicationClassLoader``.
  /// It is idempotent: when several libraries in one process call it, they all
  /// get the same instance and the first captured class loader.
  ///
  /// ```swift
  /// @_cdecl("JNI_OnLoad")
  /// public func JNI_OnLoad(javaVM: JavaVMPointer, reserved: UnsafeMutableRawPointer?) -> jint {
  ///   JavaVirtualMachine.onLoad(javaVM)
  ///   return JNI_VERSION_1_6
  /// }
  /// ```
  @discardableResult
  public static func onLoad(_ javaVM: JavaVMPointer) -> JavaVirtualMachine {
    nonisolated(unsafe) let javaVM = javaVM
    let virtualMachine = sharedJVM.withLock { state in
      if let existing = state, existing.jvm == javaVM {
        return existing
      }
      let adopted = JavaVirtualMachine(adoptingJVM: javaVM)
      publish(adopted, into: &state)
      return adopted
    }

    if virtualMachine.applicationClassLoaderState.withLock({ $0 == nil }),
      let environment = try? virtualMachine.environment()
    {
      virtualMachine.captureContextClassLoader(in: environment)
    }
    return virtualMachine
  }

  /// The application's class loader as a global reference, or `nil` if none has
  /// been captured by ``onLoad(_:)`` or set with ``setApplicationClassLoader(_:in:)``.
  ///
  /// Threads that ``environment(asDaemon:)`` attaches get this loader as their
  /// context class loader, and ``findClass(_:in:)`` falls back to it.
  public var applicationClassLoader: jobject? {
    applicationClassLoaderState.withLock { $0?.loader }
  }

  /// Sets the application class loader, for hosts where ``onLoad(_:)`` can't
  /// capture it (for example, a test runner that loads the library from a
  /// native thread). Passing `nil` clears it.
  ///
  /// The previous loader's global reference is kept alive, because threads may
  /// still be using it.
  public func setApplicationClassLoader(_ loader: jobject?, in environment: JNIEnvironment) {
    let state = loader.flatMap { ApplicationClassLoader(loader: $0, in: environment) }
    applicationClassLoaderState.withLock { $0 = state }
  }

  /// Finds a class by name, trying `FindClass` first and then the ``applicationClassLoader``.
  ///
  /// The name may be in JNI form (`java/lang/String`) or binary form
  /// (`java.lang.String`); it is converted to whichever form each lookup needs.
  /// (`FindClass` rejects dotted names, and CheckJNI aborts on them.)
  ///
  /// `FindClass` resolves through the class loader of the calling native method,
  /// or the system class loader on threads attached from native code, so
  /// application classes are only found through the fallback there.
  ///
  /// - Returns: A local reference, or `nil` if the class can't be found. No Java
  ///   exception is left pending.
  public func findClass(_ name: String, in environment: JNIEnvironment) -> jclass? {
    let interface = environment.interface
    let slashedName = String(name.map { $0 == "." ? "/" : $0 })
    if let found = interface.FindClass(environment, slashedName) {
      return found
    }
    interface.ExceptionClear(environment)

    guard let state = applicationClassLoaderState.withLock({ $0 }) else {
      return nil
    }
    let dottedName = String(name.map { $0 == "/" ? "." : $0 })
    guard let javaName = dottedName.getJNIValue(in: environment) else {
      return nil
    }
    defer { interface.DeleteLocalRef(environment, javaName) }
    var arguments = [jvalue(l: javaName)]
    let found = interface.CallObjectMethodA(environment, state.loader, state.loadClass, &arguments)
    if interface.ExceptionCheck(environment) != 0 {
      interface.ExceptionClear(environment)
      return nil
    }
    return found
  }

  /// Captures the current thread's context class loader, if it has one.
  func captureContextClassLoader(in environment: JNIEnvironment) {
    let interface = environment.interface
    guard let threadClass = interface.FindClass(environment, "java/lang/Thread") else {
      interface.ExceptionClear(environment)
      return
    }
    defer { interface.DeleteLocalRef(environment, threadClass) }
    guard
      let currentThreadID = interface.GetStaticMethodID(
        environment,
        threadClass,
        "currentThread",
        "()Ljava/lang/Thread;"
      ),
      let getLoaderID = interface.GetMethodID(
        environment,
        threadClass,
        "getContextClassLoader",
        "()Ljava/lang/ClassLoader;"
      ),
      let thread = interface.CallStaticObjectMethodA(environment, threadClass, currentThreadID, nil)
    else {
      interface.ExceptionClear(environment)
      return
    }
    defer { interface.DeleteLocalRef(environment, thread) }
    guard let loader = interface.CallObjectMethodA(environment, thread, getLoaderID, nil) else {
      // Android gives natively attached threads a null context class loader.
      interface.ExceptionClear(environment)
      return
    }
    defer { interface.DeleteLocalRef(environment, loader) }
    let state = ApplicationClassLoader(loader: loader, in: environment)
    applicationClassLoaderState.withLock { current in
      if current == nil {
        current = state
      }
    }
  }

  /// Sets the application class loader as the context class loader of a thread
  /// that was just attached.
  func applyApplicationClassLoader(to environment: JNIEnvironment) {
    guard let state = applicationClassLoaderState.withLock({ $0 }) else {
      return
    }
    let interface = environment.interface
    guard let thread = interface.CallStaticObjectMethodA(environment, state.threadClass, state.currentThread, nil)
    else {
      interface.ExceptionClear(environment)
      return
    }
    defer { interface.DeleteLocalRef(environment, thread) }
    var arguments = [jvalue(l: state.loader)]
    interface.CallVoidMethodA(environment, thread, state.setContextClassLoader, &arguments)
    if interface.ExceptionCheck(environment) != 0 {
      interface.ExceptionClear(environment)
    }
  }
}

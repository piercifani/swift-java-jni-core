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

import Foundation
import Testing

@testable import SwiftJavaJNICore

/// `jnicoretest.Probe` compiled with `javac --release 8`; it is not on the JVM's class path:
/// `package jnicoretest; public class Probe { public static int answer() { return 42; } }`
private let probeClassBase64 =
  "yv66vgAAADQADwoAAgADBwAEDAAFAAYBABBqYXZhL2xhbmcvT2JqZWN0AQAGPGluaXQ+AQADKClWBwAIAQARam5pY29yZXRlc3QvUHJvYmUBAARDb2RlAQAPTGluZU51bWJlclRhYmxlAQAGYW5zd2VyAQADKClJAQAKU291cmNlRmlsZQEAClByb2JlLmphdmEAIQAHAAIAAAAAAAIAAQAFAAYAAQAJAAAAHQABAAEAAAAFKrcAAbEAAAABAAoAAAAGAAEAAAACAAkACwAMAAEACQAAABsAAQAAAAAAAxAqrAAAAAEACgAAAAYAAQAAAAIAAQANAAAAAgAO"

@Suite(.serialized)
struct ApplicationClassLoaderTests {

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform))
  func onLoadAdoptsTheSharedInstance() throws {
    let shared = try JavaVirtualMachine.shared()
    let env = try shared.environment()
    var javaVM: JavaVMPointer? = nil
    #expect(env.interface.GetJavaVM(env, &javaVM) == JNI_OK)

    // A second library calling onLoad for the same JVM gets the same instance.
    #expect(JavaVirtualMachine.onLoad(try #require(javaVM)) === shared)
    #expect(JavaVirtualMachine.onLoad(try #require(javaVM)) === shared)
    #expect(JavaVirtualMachine.current === shared)
  }

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform))
  func findClassAcceptsDottedAndSlashedNames() throws {
    let vm = try JavaVirtualMachine.shared()
    let env = try vm.environment()
    let slashed = try #require(vm.findClass("java/lang/String", in: env))
    let dotted = try #require(vm.findClass("java.lang.String", in: env))
    #expect(env.interface.IsSameObject(env, slashed, dotted) == JNI_TRUE)
    #expect(vm.findClass("no.such.Class", in: env) == nil)
    #expect(env.interface.ExceptionCheck(env) == JNI_FALSE)
  }

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform))
  func applicationClassLoaderReachesNativeThreads() throws {
    let vm = try JavaVirtualMachine.shared()
    let env = try vm.environment()
    let interface = env.interface
    let previous = vm.applicationClassLoaderState.withLock { $0 }
    defer { vm.applicationClassLoaderState.withLock { $0 = previous } }

    #if os(Android)
    // ART can't load JVM bytecode, so only the attach path is checked here: any loader works,
    // because ART gives natively attached threads a null context class loader.
    let loader = try systemClassLoader(in: env)
    defer { interface.DeleteLocalRef(env, loader) }
    vm.setApplicationClassLoader(loader, in: env)
    let expectedAnswer: jint = 0
    #else
    let loader = try makeProbeClassLoader(in: env)
    defer { interface.DeleteLocalRef(env, loader) }

    // Not visible to FindClass on this (natively attached) thread.
    #expect(interface.FindClass(env, "jnicoretest/Probe") == nil)
    interface.ExceptionClear(env)
    #expect(vm.findClass("jnicoretest/Probe", in: env) == nil)

    vm.setApplicationClassLoader(loader, in: env)
    #expect(interface.IsSameObject(env, vm.applicationClassLoader, loader) == JNI_TRUE)

    // findClass falls back to the application class loader.
    let probe = try #require(vm.findClass("jnicoretest/Probe", in: env))
    #expect(try callAnswer(on: probe, in: env) == 42)
    #expect(interface.ExceptionCheck(env) == JNI_FALSE)
    let expectedAnswer: jint = 42
    #endif

    // A thread attached by environment() gets the application class loader as its context loader.
    final class Result: @unchecked Sendable {
      var contextLoaderIsApplicationLoader = false
      var answer: jint = 0
      var error: String?
    }
    let result = Result()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
      defer { done.signal() }
      do {
        let threadEnv = try vm.environment()
        let threadInterface = threadEnv.interface
        let threadClass = threadInterface.FindClass(threadEnv, "java/lang/Thread")
        let currentThread = threadInterface.GetStaticMethodID(
          threadEnv,
          threadClass,
          "currentThread",
          "()Ljava/lang/Thread;"
        )
        let getLoader = threadInterface.GetMethodID(
          threadEnv,
          threadClass,
          "getContextClassLoader",
          "()Ljava/lang/ClassLoader;"
        )
        let javaThread = threadInterface.CallStaticObjectMethodA(threadEnv, threadClass, currentThread, nil)
        let contextLoader = threadInterface.CallObjectMethodA(threadEnv, javaThread, getLoader, nil)
        result.contextLoaderIsApplicationLoader =
          threadInterface.IsSameObject(threadEnv, contextLoader, vm.applicationClassLoader) == JNI_TRUE
        if expectedAnswer != 0, let probe = vm.findClass("jnicoretest/Probe", in: threadEnv) {
          result.answer = try callAnswer(on: probe, in: threadEnv)
        }
      } catch {
        result.error = "\(error)"
      }
    }
    thread.start()
    done.wait()

    #expect(result.error == nil)
    #expect(result.contextLoaderIsApplicationLoader)
    #expect(result.answer == expectedAnswer)
  }
}

private struct JNICallFailed: Error {}

private func callAnswer(on probe: jclass, in env: JNIEnvironment) throws -> jint {
  guard let answer = env.interface.GetStaticMethodID(env, probe, "answer", "()I") else {
    throw JNICallFailed()
  }
  return env.interface.CallStaticIntMethodA(env, probe, answer, nil)
}

private func systemClassLoader(in env: JNIEnvironment) throws -> jobject {
  let i = env.interface
  guard let loaderClass = i.FindClass(env, "java/lang/ClassLoader"),
    let getSystem = i.GetStaticMethodID(env, loaderClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;"),
    let loader = i.CallStaticObjectMethodA(env, loaderClass, getSystem, nil)
  else {
    i.ExceptionClear(env)
    throw JNICallFailed()
  }
  return loader
}

/// Writes Probe.class to a temporary directory and returns a local ref to a URLClassLoader over it.
private func makeProbeClassLoader(in env: JNIEnvironment) throws -> jobject {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("jnicore-\(UUID().uuidString)")
  let package = root.appendingPathComponent("jnicoretest")
  try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
  try Data(base64Encoded: probeClassBase64)!.write(to: package.appendingPathComponent("Probe.class"))

  let i = env.interface
  func require<T>(_ value: T?) throws -> T {
    guard let value, i.ExceptionCheck(env) == JNI_FALSE else {
      i.ExceptionDescribe(env)
      i.ExceptionClear(env)
      throw JNICallFailed()
    }
    return value
  }
  let fileClass = try require(i.FindClass(env, "java/io/File"))
  let fileInit = try require(i.GetMethodID(env, fileClass, "<init>", "(Ljava/lang/String;)V"))
  var fileArgs = [jvalue(l: root.path.getJNIValue(in: env))]
  let file = try require(i.NewObjectA(env, fileClass, fileInit, &fileArgs))
  let toURI = try require(i.GetMethodID(env, fileClass, "toURI", "()Ljava/net/URI;"))
  let uri = try require(i.CallObjectMethodA(env, file, toURI, nil))
  let uriClass = try require(i.FindClass(env, "java/net/URI"))
  let toURL = try require(i.GetMethodID(env, uriClass, "toURL", "()Ljava/net/URL;"))
  let url = try require(i.CallObjectMethodA(env, uri, toURL, nil))
  let urlClass = try require(i.FindClass(env, "java/net/URL"))
  let urls = try require(i.NewObjectArray(env, 1, urlClass, url))
  let loaderClass = try require(i.FindClass(env, "java/net/URLClassLoader"))
  let loaderInit = try require(i.GetMethodID(env, loaderClass, "<init>", "([Ljava/net/URL;)V"))
  var loaderArgs = [jvalue(l: urls)]
  return try require(i.NewObjectA(env, loaderClass, loaderInit, &loaderArgs))
}

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

import Testing

@testable import SwiftJavaJNICore

@Suite
struct ByteArrayTests {

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform), arguments: [0, 1, 5, 64 * 1024])
  func roundTrip(count: Int) throws {
    let env = try JavaVirtualMachine.shared().environment()
    let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    let array = try bytes.withUnsafeBytes { try env.newByteArray($0) }
    defer { env.interface.DeleteLocalRef(env, array) }
    #expect(env.interface.GetArrayLength(env, array) == jsize(count))

    let read = try env.withByteArrayElements(array) { Array(UnsafeRawBufferPointer($0)) }
    #expect(read == bytes)
  }

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform))
  func releaseModesControlWriteBack() throws {
    let env = try JavaVirtualMachine.shared().environment()
    let array = try [UInt8](repeating: 0, count: 4).withUnsafeBytes { try env.newByteArray($0) }
    defer { env.interface.DeleteLocalRef(env, array) }

    try env.withByteArrayElements(array, releaseMode: .copyBack) { $0[0] = 7 }
    try env.withByteArrayElements(array, releaseMode: .discard) { $0[1] = 9 } // dropped if the JVM gave us a copy

    var region = [jbyte](repeating: 0, count: 4)
    env.interface.GetByteArrayRegion(env, array, 0, 4, &region)
    #expect(region[0] == 7)
  }

  @Test(.enabled(if: JavaVirtualMachineTests.isSupportedPlatform))
  func newByteArrayThrowsWhenTooLarge() throws {
    let env = try JavaVirtualMachine.shared().environment()
    withUnsafeBytes(of: 0 as UInt8) { one in
      // Larger than any JVM allows; NewByteArray fails before the bytes are read.
      let tooLarge = UnsafeRawBufferPointer(start: one.baseAddress, count: Int(jsize.max))
      do {
        _ = try env.newByteArray(tooLarge)
        Issue.record("expected arrayOutOfMemory")
      } catch JNIError.arrayOutOfMemory(length: let length) {
        #expect(length == Int(jsize.max))
      } catch {
        Issue.record("unexpected \(error)")
      }
    }
    #expect(env.interface.ExceptionCheck(env) == JNI_FALSE)
  }
}

import Foundation

//swiftlint:disable type_name
// TODO: Use `package` access level when we bump to Swift 5.9
/// Implementation detail, may have breaking changes from time to time.
/// "Hidden" from users to avoid exposing implementation details such as
/// the ``Codable`` conformance, since the builder API has to be pretty
/// much perfectly backwards compatible.
public struct _BuilderContextImpl: BuilderContext, Codable {
  public var buildDirectory: URL

  public init(buildDirectory: URL) {
    self.buildDirectory = buildDirectory
  }

  enum Error: LocalizedError {
    case nonZeroExitStatus(Int)
  }

  public func run(_ command: String, _ arguments: [String]) async throws {
    let process = Process()
    #if os(Windows)
      process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
      process.arguments = ["/c", command] + arguments
    #else
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [command] + arguments
    #endif

      process.standardInput = Pipe()
      let outputPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = outputPipe

      outputPipe.fileHandleForReading.readabilityHandler = {
          if let string = String(data: $0.availableData, encoding: .utf8) {
              print("[output] \(string)", terminator: "")
          }
      }

      defer { outputPipe.fileHandleForReading.readabilityHandler = nil }

    try await process.runAndWait()

    let exitStatus = Int(process.terminationStatus)
    guard exitStatus == 0 else {
      throw Error.nonZeroExitStatus(exitStatus)
    }
  }
}
//swiftlint:enable type_name

extension Process {
    func runAndWait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            terminationHandler = { process in
                continuation.resume()
            }

            do {
                try run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

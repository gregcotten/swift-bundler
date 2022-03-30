import Logging
import Rainbow

extension Logger.Level {
  var colored: String {
    switch self {
      case .critical:
        return rawValue.red.bold
      case .error:
        return rawValue.red
      case .warning:
        return rawValue.yellow
      case .notice:
        return rawValue.blue
      case .info:
        return rawValue.blue
      case .debug:
        return rawValue.lightWhite
      case .trace:
        return rawValue.lightWhite
    }
  }
}

/// Swift Bundler's basic log handler.
struct Handler: LogHandler {
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .debug
  
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { nil }
    set(newValue) { }
  }

  func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
    print("\(level.rawValue.blue): \(message)")
  }
}

/// The global logger.
var log = Logger(label: "Bundler") { _ in
  return Handler()
}

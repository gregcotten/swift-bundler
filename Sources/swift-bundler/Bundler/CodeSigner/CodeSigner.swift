import Foundation
import Parsing

/// A utility for codesigning Darwin application bundles
enum CodeSigner {
  /// The path to the `codesign` tool.
  static let codesignToolPath = "/usr/bin/codesign"
  /// The path to the `security` tool.
  static let securityToolPath = "/usr/bin/security"

  /// An identity that can be used to codesign a bundle.
  struct Identity {
    /// The identity's id.
    var id: String
    /// The identity's display name.
    var name: String
  }

  /// Generates an iOS entitlements file.
  /// - Parameters:
  ///   - outputFile: The destination for the generated entitlements file.
  ///   - bundle: The app bundle to sign.
  ///   - identityId: The id of the codesigning identity to use.
  ///   - bundleIdentifier: The identifier of the app bundle.
  /// - Returns: A failure if the `codesign` command fails to run.
  static func generateEntitlementsFile(
    at outputFile: URL,
    for bundle: URL,
    identityId: String,
    bundleIdentifier: String
  ) -> Result<Void, CodeSignerError> {
    return getTeamIdentifier(from: bundle)
      .map { teamIdentifier -> String in
        let content = generateEntitlementsContent(
          teamIdentifier: teamIdentifier,
          bundleIdentifier: bundleIdentifier
        )
        return content
      }
      .andThen { entitlementsContent in
        Result {
          try entitlementsContent.write(
            to: outputFile,
            atomically: false,
            encoding: .utf8
          )
        }.mapError(CodeSignerError.failedToWriteEntitlements)
      }
  }

  /// Signs a Darwin app bundle.
  ///
  /// If no entitlements are provided and the platform requires provisioning
  /// profiles, some basic entitlements get automatically generated. Otherwise
  /// the application bundle will fail to verify.
  /// - Parameters:
  ///   - bundle: The app bundle to sign.
  ///   - identityId: The id of the codesigning identity to use.
  ///   - bundleIdentifier: The app's bundle identifier.
  ///   - platform: The target platform getting built for.
  ///   - entitlements: The app's entitlements file.
  /// - Returns: A failure if the `codesign` command fails to run.
  static func signAppBundle(
    bundle: URL,
    identityId: String,
    bundleIdentifier: String,
    platform: ApplePlatform,
    entitlements: URL?
  ) -> Result<Void, CodeSignerError> {
    log.info("Codesigning app bundle")

    let librariesDirectory = bundle.appendingPathComponent("Libraries")
    if FileManager.default.itemExists(at: librariesDirectory, withType: .directory) {
      let contents: [URL]
      do {
        contents = try FileManager.default.contentsOfDirectory(
          at: librariesDirectory,
          includingPropertiesForKeys: nil
        )
      } catch {
        return .failure(.failedToEnumerateDynamicLibraries(error))
      }

      for file in contents where file.pathExtension == "dylib" {
        if case let .failure(error) = sign(file: file, identityId: identityId) {
          return .failure(error)
        }
      }
    }

    // Generate entitlements file if required by platform and not provided
    let entitlementsFile: URL?
    if let entitlements = entitlements {
      entitlementsFile = entitlements
    } else if platform.requiresProvisioningProfiles {
      let file =
        FileManager.default.temporaryDirectory
        / "\(UUID().uuidString).xcent"

      entitlementsFile = file

      if case .failure(let error) = CodeSigner.generateEntitlementsFile(
        at: file,
        for: bundle,
        identityId: identityId,
        bundleIdentifier: bundleIdentifier
      ) {
        return .failure(error)
      }
    } else {
      entitlementsFile = nil
    }

    return sign(
      file: bundle,
      identityId: identityId,
      entitlements: entitlementsFile
    )
  }

  /// Signs a binary or app bundle.
  /// - Parameters:
  ///   - bundle: The binary or app bundle to sign.
  ///   - identityId: The id of the codesigning identity to use.
  ///   - entitlements: The entitlements to give the file (only valid for app bundles).
  /// - Returns: A failure if the `codesign` command fails.
  static func sign(
    file: URL,
    identityId: String,
    entitlements: URL? = nil
  ) -> Result<Void, CodeSignerError> {
    let entitlementArguments: [String]
    if let entitlements = entitlements {
      entitlementArguments = [
        "--entitlements", entitlements.path,
        "--generate-entitlement-der",
      ]
    } else {
      entitlementArguments = []
    }

    let arguments =
      entitlementArguments + [
        "--force", "--deep",
        "--sign", identityId,
        file.path,
      ]

    let process = Process.create(
      codesignToolPath,
      arguments: arguments
    )

    return process.runAndWait().mapError { error in
      return .failedToRunCodesignTool(error)
    }
  }

  /// Signs a binary or app bundle using ad-hoc signing.
  /// - Parameter file: The file to sign.
  /// - Returns: A failure if the `codesign` command fails.
  static func signAdHoc(file: URL) -> Result<Void, CodeSignerError> {
    let process = Process.create(
      codesignToolPath,
      arguments: ["--force", "-s", "-", file.path]
    )

    return process.runAndWait().mapError { error in
      return .failedToRunCodesignTool(error)
    }
  }

  /// Enumerates the user's available codesigning identities.
  /// - Returns: An array of identities, or a failure if the `security` command fails or produces invalid output.
  static func enumerateIdentities() -> Result<[Identity], CodeSignerError> {
    let process = Process.create(
      securityToolPath,
      arguments: ["find-identity", "-pcodesigning", "-v"]
    )

    return process.getOutput()
      .mapError { error in
        return .failedToEnumerateIdentities(error)
      }
      .andThen { output in
        // Example input: `52635337831A02427192D4FC5EC8528323456F17 "Apple Development: stackotter@stackotter.dev (LK3JHG2345)"`
        let identityParser = Parse {
          PrefixThrough(") ")
          PrefixUpTo(" ").map { (id: Substring) in
            String(id)
          }
          " "
          OneOf {
            PrefixUpTo("\n")
            Rest<Substring>()
          }.map { (substring: Substring) -> String in
            // Remove quotation marks
            let withoutQuotationMarks: Substring = substring.dropFirst().dropLast()
            return String(withoutQuotationMarks)
          }
        }.map { (_: Substring, id: String, name: String) in
          return Identity(id: id, name: name)
        }

        let identityListParser = Parse {
          Many {
            identityParser
          }
          Rest<Substring>()
        }.map { (identities: [Identity], _: Substring) in
          return identities
        }

        let identities: [Identity]
        do {
          identities = try identityListParser.parse(output)
        } catch {
          return .failure(.failedToParseIdentityList(error))
        }

        return .success(identities)
      }
  }

  static func getTeamIdentifier(from bundle: URL) -> Result<String, CodeSignerError> {
    let provisioningProfile = bundle / "embedded.mobileprovision"
    return ProvisioningProfileManager.loadProvisioningProfile(provisioningProfile)
      .mapError { error in
        CodeSignerError.failedToLoadProvisioningProfile(provisioningProfile, error)
      }
      .andThen { profile in
        guard let identifier = profile.teamIdentifierArray.first else {
          return .failure(.provisioningProfileMissingTeamIdentifier)
        }
        return .success(identifier)
      }
  }

  /// Generates the contents of an entitlements file.
  static func generateEntitlementsContent(
    teamIdentifier: String,
    bundleIdentifier: String
  ) -> String {
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      	<key>application-identifier</key>
      	<string>\(teamIdentifier).\(bundleIdentifier)</string>
      	<key>com.apple.developer.team-identifier</key>
      	<string>\(teamIdentifier)</string>
      	<key>get-task-allow</key>
      	<true/>
      </dict>
      </plist>
      """
  }
}

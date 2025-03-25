import Foundation

/// A bundler targeting generic Windows systems. Arranges executables, resources,
/// and dynamic libraries into a standard directory layout.
///
/// This bundler is great to use during development as it provides a realistic
/// runtime environment while keeping bundling overhead low, allowing for quick
/// iteration.
///
/// The other Windows bundlers provided by Swift Bundler rely on this bundler to
/// do all of the heavy lifting. After running the generic bundler they simply
/// take the output and bundle it up into an often distro-specific package file
/// or standalone executable.
enum GenericWindowsBundler: Bundler {
  static let outputIsRunnable = true

  struct Context {}

  /// Describes the structure of a bundle generated by ``GenericWindowsBundler``.
  struct BundleStructure {
    /// The root directory of the bundle.
    var root: URL
    /// The directory containing modules (executables and dynamic libraries).
    var modules: URL
    /// The directory containing resources. Currently the same as ``modules``.
    var resources: URL
    /// The main executable.
    var mainExecutable: URL

    /// Represents the bundle structure using the simple ``BundlerOutputStructure``
    /// data type.
    var asOutputStructure: BundlerOutputStructure {
      BundlerOutputStructure(bundle: root, executable: mainExecutable)
    }

    /// All directories in the structure. Used when creating the structure
    /// on disk.
    private var directories: [URL] {
      [root, modules, resources]
    }

    /// Computes the bundle structure corresponding to the provided context.
    init(at root: URL, forApp appName: String, withIdentifier appIdentifier: String) {
      self.root = root
      modules = root
      resources = root
      mainExecutable = modules / "\(appName).exe"
    }

    /// Creates all directories (including intermediate directories) required to
    /// create this bundle structure.
    func createDirectories() -> Result<Void, Error> {
      directories.tryForEach { directory in
        FileManager.default.createDirectory(
          at: directory,
          onError: Error.failedToCreateDirectory
        )
      }
    }
  }

  private static let dllBundlingAllowList: [String] = [
    "swiftCore",
    "swiftCRT",
    "swiftDispatch",
    "swiftDistributed",
    "swiftObservation",
    "swiftRegexBuilder",
    "swiftRemoteMirror",
    "swiftSwiftOnoneSupport",
    "swiftSynchronization",
    "swiftWinSDK",
    "Foundation",
    "FoundationXML",
    "FoundationNetworking",
    "FoundationEssentials",
    "FoundationInternationalization",
    "BlocksRuntime",
    "_FoundationICU",
    "_InternalSwiftScan",
    "_InternalSwiftStaticMirror",
    "swift_Concurrency",
    "swift_RegexParser",
    "swift_StringProcessing",
    "swift_Differentiation",
    "concrt140",
    "msvcp140",
    "msvcp140_1",
    "msvcp140_2",
    "msvcp140_atomic_wait",
    "msvcp140_codecvt_ids",
    "vccorlib140",
    "vcruntime140",
    "vcruntime140_1",
    "vcruntime140_threads",
    "dispatch",
  ].map { "\($0).dll".lowercased() }

  static func computeContext(
    context: BundlerContext,
    command: BundleCommand,
    manifest: PackageManifest
  ) -> Result<Context, Error> {
    // GenericWindowsBundler's additional context only exists to allow other
    // bundlers to configure it when building on top of it, so for command-line
    // usage we can just use the defaults.
    .success(Context())
  }

  static func intendedOutput(
    in context: BundlerContext,
    _ additionalContext: Context
  ) -> BundlerOutputStructure {
    let bundle = context.outputDirectory
      .appendingPathComponent("\(context.appName).generic")
    let structure = BundleStructure(
      at: bundle,
      forApp: context.appName,
      withIdentifier: context.appConfiguration.identifier
    )
    return structure.asOutputStructure
  }

  static func bundle(
    _ context: BundlerContext,
    _ additionalContext: Context
  ) async -> Result<BundlerOutputStructure, Error> {
    await bundle(context, additionalContext)
      .map(\.asOutputStructure)
  }

  static func bundle(
    _ context: BundlerContext,
    _ additionalContext: Context
  ) async -> Result<BundleStructure, Error> {
    let root = intendedOutput(in: context, additionalContext).bundle
    let appBundleName = root.lastPathComponent

    log.info("Bundling '\(appBundleName)'")

    let executableArtifact = context.productsDirectory
      .appendingPathComponent("\(context.appConfiguration.product).exe")

    let structure = BundleStructure(
      at: root,
      forApp: context.appName,
      withIdentifier: context.appConfiguration.identifier
    )

    return await structure.createDirectories()
      .andThen { _ in
        copyExecutable(at: executableArtifact, to: structure.mainExecutable)
      }
      .andThen { _ in
        // Copy all executable dependencies into the bundle next to the main
        // executable
        context.builtDependencies.filter { (_, dependency) in
          dependency.product.type == .executable
        }.tryForEach { (name, dependency) in
          dependency.artifacts.tryForEach { artifact in
            let source = artifact.location
            let destination = structure.modules / source.lastPathComponent
            return FileManager.default.copyItem(
              at: source,
              to: destination
            ).mapError { error in
              Error.failedToCopyExecutableDependency(
                name: name,
                source: source,
                destination: destination,
                error
              )
            }
          }
        }
      }
      .andThen { _ in
        copyResources(
          from: context.productsDirectory,
          to: structure.resources
        )
      }
      .andThen { _ in
        log.info("Copying dynamic libraries (and Swift runtime)")
        return await copyDynamicLibraryDependencies(
          of: structure.mainExecutable,
          to: structure.modules,
          productsDirectory: context.productsDirectory
        )
      }
      .andThen { _ in
        // Insert metadata after copying dynamic library dependencies cause
        // trailing data can probably cause some ELF editing tools to explode
        let metadata = MetadataInserter.metadata(for: context.appConfiguration)
        return MetadataInserter.insert(
          metadata,
          into: structure.mainExecutable
        ).mapError(Error.failedToInsertMetadata)
      }
      .replacingSuccessValue(with: structure)
  }

  // MARK: Private methods

  /// Copies dynamic library dependencies of the specified module to the given
  /// destination folder. Discovers dependencies recursively with `dumpbin`.
  /// Currently just ignores any dependencies that it can't locate (since there
  /// are many dlls that we don't want to distribute in the first place, such as
  /// ones that come with Windows).
  /// - Returns: The original URLs of copied dependencies.
  private static func copyDynamicLibraryDependencies(
    of module: URL,
    to destination: URL,
    productsDirectory: URL
  ) async -> Result<Void, Error> {
    let productsDirectory = productsDirectory.actuallyResolvingSymlinksInPath()
    return await Process.create(
      "dumpbin",
      arguments: ["/DEPENDENTS", module.path],
      runSilentlyWhenNotVerbose: false
    ).getOutput().mapError { error in
      .failedToEnumerateDynamicDependencies(error)
    }.andThen { output -> Result<[URL], Error> in
      let lines = output.split(
        omittingEmptySubsequences: false,
        whereSeparator: \.isNewline
      )
      let headingLine = "  Image has the following dependencies:"
      guard
        let headingIndex = lines.firstIndex(of: headingLine[...])
      else {
        let error = Error.failedToParseDumpbinOutput(
          output: output,
          message: "Couldn't find section heading"
        )
        return .failure(error)
      }

      let startIndex = headingIndex + 2
      guard let endIndex = lines[startIndex...].firstIndex(of: "") else {
        let error = Error.failedToParseDumpbinOutput(
          output: output,
          message: "Couldn't find end of section"
        )
        return .failure(error)
      }

      let dllNames = lines[startIndex..<endIndex].map { line in
        String(line.trimmingCharacters(in: .whitespaces))
      }

      return dllNames.tryMap { dllName -> Result<URL?, Error> in
        log.debug("Resolving '\(dllName)'")

        // If the dll exists next to the `exe` it's a product of the build
        // and we should copy it across.
        let guess = productsDirectory / dllName
        if guess.exists() {
          return .success(guess)
        }

        // If the dll isn't a product of the SwiftPM build, we should only
        // copy it across if it's known (cause there are many DLLs, such as
        // ones shipped with Windows, that we shouldn't be distributing with
        // apps).
        guard dllBundlingAllowList.contains(dllName.lowercased()) else {
          return .success(nil)
        }

        // Parse the PATH environment variable.
        let pathVar = ProcessInfo.processInfo.environment["Path"] ?? ""
        let pathDirectories = pathVar.split(separator: ";").map { path in
          URL(fileURLWithPath: String(path))
        }

        // Search each directory on the path for the DLL we're looking for.
        return pathDirectories.map { directory -> URL in
          directory / dllName
        }.first { (dll: URL) in
          dll.exists()
        }.okOr(Error.failedToResolveDLLName(dllName)).map(Optional.some)
      }.map { dlls in
        // Ignore nils, since they're the ones we explicitly chose to skip.
        dlls.compactMap { $0 }
      }
    }.andThen { (dlls: [URL]) in
      // Copy the discovered DLLs to the destination directory, and recurse to
      // ensure that the DLLs get their dependencies copied across as well
      // (in case the main executable doesn't directly depend on said
      // dependencies).
      await dlls.tryForEach { dll in
        let destinationFile = destination / dll.lastPathComponent

        // We've already copied this dll across so we don't need to copy it or
        // recurse to its dependencies.
        guard !destinationFile.exists() else {
          return .success()
        }

        // Resolve symlinks in case the library itself is a symlinnk (we want
        // to copy the actual library not the symlink).
        let resolvedSourceFile = dll.actuallyResolvingSymlinksInPath()

        log.debug("Copying '\(dll.path)'")
        let pdbFile = resolvedSourceFile.replacingPathExtension(with: "pdb")
        return await FileManager.default.copyItem(
          at: resolvedSourceFile,
          to: destinationFile,
          onError: Error.failedToCopyDLL
        ).andThen(if: pdbFile.exists()) { _ in
          // Copy dll's pdb file if present
          let destinationPDBFile = destinationFile.replacingPathExtension(
            with: "pdb"
          )
          return FileManager.default.copyItem(
            at: pdbFile,
            to: destinationPDBFile,
            onError: Error.failedToCopyPDB
          )
        }.andThen { _ in
          // Recurse to ensure that we copy indirect dependencies of the main
          // executable as well as the direct ones that `dumpbin` lists.
          await copyDynamicLibraryDependencies(
            of: resolvedSourceFile,
            to: destination,
            productsDirectory: productsDirectory
          )
        }
      }
    }
  }

  /// Copies any resource bundles produced by the build system and changes
  /// their extension from `.resources` to `.bundle` for consistency with
  /// bundling on Apple platforms.
  private static func copyResources(
    from sourceDirectory: URL,
    to destinationDirectory: URL
  ) -> Result<Void, Error> {
    return FileManager.default.contentsOfDirectory(
      at: sourceDirectory,
      onError: Error.failedToEnumerateResourceBundles
    )
    .andThen { contents in
      contents.filter { file in
        file.pathExtension == "resources"
          && FileManager.default.itemExists(at: file, withType: .directory)
      }
      .tryForEach { bundle in
        log.info("Copying resource bundle '\(bundle.lastPathComponent)'")

        let bundleName = bundle.deletingPathExtension().lastPathComponent

        let destinationBundle: URL
        if bundleName == "swift-windowsappsdk_CWinAppSDK" {
          // swift-windowsappsdk expects the bootstrap dll to be at the
          // location that SwiftPM puts it at, so we mustn't change the
          // extension from `.resources` to `.bundle` in this case.
          destinationBundle = destinationDirectory / "\(bundleName).resources"
        } else {
          destinationBundle = destinationDirectory / "\(bundleName).bundle"
        }

        return FileManager.default.copyItem(
          at: bundle, to: destinationBundle,
          onError: Error.failedToCopyResourceBundle
        )
      }
    }
  }

  /// Copies the built executable into the app bundle. Also copies the
  /// executable's corresponding `.pdb` debug info file if found.
  /// - Parameters:
  ///   - source: The location of the built executable.
  ///   - destination: The target location of the built executable (the file not the directory).
  /// - Returns: If an error occus, a failure is returned.
  private static func copyExecutable(
    at source: URL,
    to destination: URL
  ) -> Result<Void, Error> {
    log.info("Copying executable")

    let pdbFile = source.replacingPathExtension(with: "pdb")
    return FileManager.default.copyItem(
      at: source,
      to: destination,
      onError: Error.failedToCopyExecutable
    ).andThen(if: pdbFile.exists()) { _ in
      let pdbDestination = destination.replacingPathExtension(with: "pdb")
      return FileManager.default.copyItem(
        at: source,
        to: pdbDestination,
        onError: Error.failedToCopyPDB
      )
    }
  }
}

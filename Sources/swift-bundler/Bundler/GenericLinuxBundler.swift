import Foundation
import Parsing

/// A bundler targeting generic Linux systems. Arranges executables, resources,
/// and dynamic libraries into a standard directory layout based off the
/// Filesystem Hierarchy Standard that Linux systems generally follow.
///
/// This bundler is great to use during development as it provides a realistic
/// runtime environment while keeping bundling overhead low, allowing for quick
/// iteration.
///
/// The other Linux bundlers provided by Swift Bundler rely on this bundler to
/// do all of the heavy lifting. After running the generic bundler they simply
/// take the output and bundle it up into an often distro-specific package file
/// or standalone executable.
enum GenericLinuxBundler: Bundler {
  static let outputIsRunnable = true

  struct Context {
    /// Used in log messages to avoid exposing that everything's just the
    /// generic Linux bundler all the way down. Doesn't affect the fact
    /// that the generic bundler's output will have the `.generic` file
    /// extension. It's up to other bundlers to transform that output
    /// into their desired output format.
    var cosmeticBundleName: String?
    /// The full path to the bundle when installed on a system. Used when
    /// generating the app's `.desktop` file. Useful for packaging bundlers
    /// such as ``RPMBundler`` that know where the app will get installed
    /// on the system. For example, a value of `/` would mean that the app
    /// has been installed to the standard Linux locations, with the
    /// executable going to `/usr/bin` etc. Defaults to `/`.
    var installationRoot = URL(fileURLWithPath: "/")
  }

  /// A parser for the output of ldd. Parses a single line.
  private static let lddLineParser = Parse {
    PrefixThrough(" => ")
    PrefixUpTo(" (")
    Rest<Substring>()
  }.map { (_: Substring, path: Substring, _: Substring) in
    String(path)
  }

  /// The list of dynamic libraries that are allowed to get bundled into
  /// the final app bundle. The reason we need an allow list in the first
  /// place is that a large proportion of dynamic libraries cause issues
  /// when distributed to different platforms (such as Gtk). So for now
  /// we just stick to bundling Swift's dependencies. Ideally we'd
  /// just generate this list from the Swift toolchain but we won't always
  /// know which Swift toolchain was used to build the binary etc. And we
  /// want to bundle `libcurl` and `libxml` as well since they're both
  /// dependencies of the Swift runtime but they're not included in
  /// the runtime itself.
  ///
  /// We don't bundle libc because that can cause all kinds of weird issues;
  /// the main one being that any external dependencies of the app are forced
  /// to use the same libc as the main executable, so if the user's machine
  /// has a different enough libc version and the main executable depends on
  /// external dependencies, then you'll probably get segfaults.
  private static let dynamicLibraryBundlingAllowList: [String] = [
    "libswiftCore",
    "libswiftGlibc",
    "libswiftDispatch",
    "libswiftDistributed",
    "libswiftObservation",
    "libswiftRegexBuilder",
    "libswiftRemoteMirror",
    "libswiftSynchronization",
    "libswiftSwiftOnoneSupport",
    "libBlocksRuntime",
    "libdispatch",
    "libswift_Volatile",
    "libswift_Concurrency",
    "libswift_RegexParser",
    "libswift_StringProcessing",
    "libswift_Backtracing",
    "libswift_Builtin_float",
    "libswift_Differentiation",
    "lib_FoundationICU",
    "lib_InternalSwiftScan",
    "lib_InternalSwiftStaticMirror",
    "libFoundation",
    "libFoundationXML",
    "libFoundationEssentials",
    "libFoundationNetworking",
    "libFoundationInternationalization",
    "libicuuc",
    "libicudata",
    "libicuucswift",
    "libicui18nswift",
    "libicudataswift",
  ]

  /// Describes the structure of a bundle generated by ``GenericLinuxBundler``.
  struct BundleStructure {
    /// The root directory of the bundle.
    var root: URL
    /// The directory containing executables.
    var bin: URL
    /// The main executable.
    var mainExecutable: URL
    /// The directory containing dynamic libraries.
    var lib: URL
    /// The directory containing resources.
    var resources: URL
    /// The app's 1024x1024 icon file.
    var icon1024x1024: URL
    /// The app's `.desktop` file.
    var desktopFile: URL
    ///  The app's `.service` file. Only used for DBus activatable apps.
    var dbusServiceFile: URL

    /// Represents the bundle structure using the simple ``BundlerOutputStructure``
    /// data type.
    var asOutputStructure: BundlerOutputStructure {
      BundlerOutputStructure(bundle: root, executable: mainExecutable)
    }

    /// All directories in the structure. Used when creating the structure
    /// on disk.
    private var directories: [URL] {
      [
        root, bin, lib, resources,
        icon1024x1024.deletingLastPathComponent(),
        desktopFile.deletingLastPathComponent(),
        dbusServiceFile.deletingLastPathComponent(),
      ]
    }

    /// Computes the bundle structure corresponding to the provided context.
    init(at root: URL, forApp appName: String, withIdentifier appIdentifier: String) {
      self.root = root
      bin = root.appendingPathComponent("usr/bin")
      mainExecutable = bin.appendingPathComponent(appName)
      lib = root.appendingPathComponent("usr/lib")
      resources = bin
      // TODO: Resize the icon to 512x512, 1024x1024 isn't supported by xdg stuff
      //   but no one checks the actual size so we store it in 512x512 and it
      //   works as a workaround.
      icon1024x1024 = root.appendingPathComponent(
        "usr/share/icons/hicolor/512x512/apps/\(appIdentifier).png"
      )
      desktopFile = root.appendingPathComponent(
        "usr/share/applications/\(Self.desktopFileName(for: appIdentifier))"
      )
      dbusServiceFile = root.appendingPathComponent(
        "usr/share/dbus-1/services/\(Self.dbusServiceFileName(for: appIdentifier))"
      )
    }

    /// Creates all directories (including intermediate directories) required to
    /// create this bundle structure.
    func createDirectories() -> Result<Void, GenericLinuxBundlerError> {
      directories.tryForEach { directory in
        FileManager.default.createDirectory(
          at: directory,
          onError: GenericLinuxBundlerError.failedToCreateDirectory
        )
      }
    }

    /// Computes the `.desktop` file name to use for the given app identifier.
    static func desktopFileName(for appIdentifier: String) -> String {
      "\(appIdentifier).desktop"
    }

    /// Computes the `.service` file name to use for the given app identifier.
    static func dbusServiceFileName(for appIdentifier: String) -> String {
      "\(appIdentifier).service"
    }
  }

  static func computeContext(
    context: BundlerContext,
    command: BundleCommand,
    manifest: PackageManifest
  ) -> Result<Context, GenericLinuxBundlerError> {
    // GenericLinuxBundler's additional context only exists to allow other
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
  ) async -> Result<BundlerOutputStructure, GenericLinuxBundlerError> {
    await bundle(context, additionalContext)
      .map(\.asOutputStructure)
  }

  static func bundle(
    _ context: BundlerContext,
    _ additionalContext: Context
  ) async -> Result<BundleStructure, GenericLinuxBundlerError> {
    let root = intendedOutput(in: context, additionalContext).bundle
    let appBundleName = root.lastPathComponent

    log.info("Bundling '\(additionalContext.cosmeticBundleName ?? appBundleName)'")

    let executableArtifact = context.productsDirectory
      .appendingPathComponent(context.appConfiguration.product)

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
          let source = dependency.location
          let destination = structure.bin / dependency.location.lastPathComponent
          return FileManager.default.copyItem(
            at: source,
            to: destination
          ).mapError { error in
            GenericLinuxBundlerError.failedToCopyExecutableDependency(
              name: name,
              source: source,
              destination: destination,
              error
            )
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
        // Create desktop file (and DBus service file if required)
        let relativeExecutablePath = structure.mainExecutable.path(
          relativeTo: structure.root
        )
        let executableLocation =
          additionalContext.installationRoot / relativeExecutablePath
        return createDesktopFile(
          at: structure.desktopFile,
          appName: context.appName,
          appConfiguration: context.appConfiguration,
          installedExecutableLocation: executableLocation
        )
        .andThen(if: context.appConfiguration.dbusActivatable) { _ in
          createDBusServiceFile(
            at: structure.dbusServiceFile,
            appIdentifier: context.appConfiguration.identifier,
            installedExecutableLocation: executableLocation
          )
        }
      }
      .andThen { _ in
        copyAppIconIfPresent(context, structure)
      }
      .andThen { _ in
        await copyDynamicLibraryDependencies(
          of: structure.mainExecutable,
          to: structure.lib,
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
        ).mapError(GenericLinuxBundlerError.failedToInsertMetadata)
      }
      .replacingSuccessValue(with: structure)
  }

  // MARK: Private methods

  /// Copies dynamic library dependencies of the specified executable file into
  /// a given destination directory, and updates the runpaths of the executable
  /// and moved dynamic
  /// libraries accordingly.
  ///
  /// For now this sticks to handling the Swift runtime libraries and dynamic
  /// libraries produced directly by the build, because there are many
  /// problematic dynamic libraries out there such as Gtk which break things
  /// when you try to distribute them.
  private static func copyDynamicLibraryDependencies(
    of appExecutable: URL,
    to destination: URL,
    productsDirectory: URL
  ) async -> Result<Void, GenericLinuxBundlerError> {
    log.info("Copying dynamic libraries (and Swift runtime)")
    let allowedLibrariesDirectory = productsDirectory.actuallyResolvingSymlinksInPath()
    return await Process.create(
      "ldd",
      arguments: [appExecutable.path],
      environment: [
        "LD_LIBRARY_PATH": allowedLibrariesDirectory.path
      ],
      runSilentlyWhenNotVerbose: false
    ).getOutput()
      .mapError { error in
        .failedToEnumerateDynamicDependencies(error)
      }
      .andThen { (output: String) -> Result<Void, GenericLinuxBundlerError> in
        await output.split(separator: "\n")
          .compactMap { line in
            // Parse each line and simply ignore any we can't parse.
            try? lddLineParser.parse(line)
          }
          .map(URL.init(fileURLWithPath:))
          .filter { library in
            // Ensure that the library is on our allow list or was a product of
            // the built.
            let libraryName = String(library.lastPathComponent.split(separator: ".")[0])
            return dynamicLibraryBundlingAllowList.contains(libraryName)
              || library.actuallyResolvingSymlinksInPath().path.starts(
                with: allowedLibrariesDirectory.path
              )
          }
          .tryForEach { library in
            return await copyDynamicLibrary(library, toDirectory: destination)
          }
      }
      .andThen { (_: Void) -> Result<Void, GenericLinuxBundlerError> in
        // Update the main executable's runpath
        let relativeDestination = destination.path(
          relativeTo: appExecutable.deletingLastPathComponent()
        )
        return await PatchElfTool.setRunpath(
          of: appExecutable, to: "$ORIGIN/\(relativeDestination)"
        )
        .mapError { error in
          .failedToUpdateMainExecutableRunpath(executable: appExecutable, error)
        }
      }
  }

  /// Copies a dynamic library to the specified destination directory. Resolves
  /// symlinks to copy the actual library and not the symlink, but uses the
  /// provided file name for the destination file (not the resolved name).
  private static func copyDynamicLibrary(
    _ source: URL,
    toDirectory destinationDirectory: URL
  ) async -> Result<Void, GenericLinuxBundlerError> {
    let destination = destinationDirectory.appendingPathComponent(
      source.lastPathComponent
    )

    // Resolve symlinks in case the library itself is a symlinnk (we want
    // to copy the actual library not the symlink).
    let resolvedSourceURL = source.actuallyResolvingSymlinksInPath()

    // Copy the library to the provided destination directory.
    return await Result.success()
      .andThen { _ in
        FileManager.default.copyItem(
          at: resolvedSourceURL,
          to: destination,
          onError: GenericLinuxBundlerError.failedToCopyDynamicLibrary
        )
      }
      .andThen { _ in
        // Update the library's runpath so that it only looks for its dependencies in
        // the current directory (before falling back to the system wide default runpath).
        await PatchElfTool.setRunpath(of: destination, to: "$ORIGIN")
          .mapError { error in
            .failedToCopyDynamicLibrary(
              source: resolvedSourceURL,
              destination: destination,
              error
            )
          }
      }
  }

  /// Copies the app's icon into the bundle if an icon was provided. Doesn't
  /// perform any resizing for now, but may in the future.
  private static func copyAppIconIfPresent(
    _ context: BundlerContext,
    _ structure: BundleStructure
  ) -> Result<Void, GenericLinuxBundlerError> {
    guard let path = context.appConfiguration.icon else {
      return .success()
    }

    let icon = context.packageDirectory.appendingPathComponent(path)
    return FileManager.default.copyItem(
      at: icon,
      to: structure.icon1024x1024,
      onError: GenericLinuxBundlerError.failedToCopyIcon
    )
  }

  /// Copies any resource bundles produced by the build system and changes
  /// their extension from `.resources` to `.bundle` for consistency with
  /// bundling on Apple platforms.
  private static func copyResources(
    from sourceDirectory: URL,
    to destinationDirectory: URL
  ) -> Result<Void, GenericLinuxBundlerError> {
    return FileManager.default.contentsOfDirectory(
      at: sourceDirectory,
      onError: GenericLinuxBundlerError.failedToEnumerateResourceBundles
    )
    .andThen { contents in
      contents.filter { file in
        file.pathExtension == "resources"
          && FileManager.default.itemExists(at: file, withType: .directory)
      }
      .tryForEach { bundle in
        log.info("Copying resource bundle '\(bundle.lastPathComponent)'")

        let bundleName = bundle.deletingPathExtension().lastPathComponent
        let destinationBundle = destinationDirectory.appendingPathComponent(
          "\(bundleName).bundle"
        )

        return FileManager.default.copyItem(
          at: bundle, to: destinationBundle,
          onError: GenericLinuxBundlerError.failedToCopyResourceBundle
        )
      }
    }
  }

  /// Copies the built executable into the app bundle.
  /// - Parameters:
  ///   - source: The location of the built executable.
  ///   - destination: The target location of the built executable (the file not the directory).
  /// - Returns: If an error occus, a failure is returned.
  private static func copyExecutable(
    at source: URL, to destination: URL
  ) -> Result<
    Void, GenericLinuxBundlerError
  > {
    log.info("Copying executable")
    do {
      try FileManager.default.copyItem(at: source, to: destination)
      return .success()
    } catch {
      return .failure(.failedToCopyExecutable(source: source, destination: destination, error))
    }
  }

  /// Creates an app's `.desktop` file.
  /// - Parameters:
  ///   - desktopFile: The desktop file to create.
  ///   - appName: The app's name.
  ///   - appConfiguration: The app's configuration.
  ///   - installedExecutableLocation: The location the the executable will end
  ///     up at on disk once installed.
  /// - Returns: If an error occurs, a failure is returned.
  private static func createDesktopFile(
    at desktopFile: URL,
    appName: String,
    appConfiguration: AppConfiguration.Flat,
    installedExecutableLocation: URL
  ) -> Result<Void, GenericLinuxBundlerError> {
    log.info("Creating '\(desktopFile.lastPathComponent)'")

    let escapedExecPath = installedExecutableLocation.path
      .replacingOccurrences(of: " ", with: "\\ ")
    var properties = [
      ("Type", "Application"),
      ("Version", "1.0"),  // The version of the target desktop spec, not the app
      ("Name", appName),
      ("Comment", ""),
      ("Exec", "\(escapedExecPath) %U"),
      ("Icon", appName),
      ("Terminal", "false"),
      ("Categories", ""),
    ]

    if appConfiguration.dbusActivatable {
      properties.append(("DBusActivatable", "true"))
    }

    if !appConfiguration.urlSchemes.isEmpty {
      properties.append(
        (
          "MimeType",
          appConfiguration.urlSchemes.map { scheme in
            "x-scheme-handler/\(scheme)"
          }.joined(separator: ";")
        )
      )
    }

    let contents = encodeIniSection(title: "Desktop Entry", properties: properties)
    let data = Data(contents.utf8)
    return data.write(to: desktopFile).mapError { error in
      .failedToCreateDesktopFile(desktopFile, error)
    }
  }

  /// Creates an app's `.service` file.
  /// - Parameters:
  ///   - dbusServiceFile: The DBus service file to create.
  ///   - appIdentifier: The app's identifier.
  ///   - installedExecutableLocation: The location the the executable will end
  ///     up at on disk once installed.
  /// - Returns: If an error occurs, a failure is returned.
  private static func createDBusServiceFile(
    at dbusServiceFile: URL,
    appIdentifier: String,
    installedExecutableLocation: URL
  ) -> Result<Void, GenericLinuxBundlerError> {
    let properties = [
      ("Name", appIdentifier),
      ("Exec", "\"\(installedExecutableLocation.path)\""),
    ]

    let contents = encodeIniSection(title: "D-BUS Service", properties: properties)
    let data = Data(contents.utf8)
    return data.write(to: dbusServiceFile).mapError { error in
      .failedToCreateDBusServiceFile(dbusServiceFile, error)
    }
  }

  private static func encodeIniSection(
    title: String,
    properties: [(String, String)]
  ) -> String {
    "[\(title)]\n" + properties.map { "\($0)=\($1)" }.joined(separator: "\n")
  }
}

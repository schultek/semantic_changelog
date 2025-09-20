import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:glob/glob.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import '../changelog.dart';
import '../packages.dart';

/// The "bump" command.
class BumpCommand extends Command<void> {
  BumpCommand() {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Analyze but do not apply the version bump.',
    );

    argParser.addMultiOption(
      'scope',
      valueHelp: 'glob',
      help: 'Include only packages with names matching the given glob. This '
          'option can be repeated.',
    );

    argParser.addMultiOption(
      'ignore',
      valueHelp: 'glob',
      help: 'Exclude packages with names matching the given glob. This option '
          'can be repeated.',
    );
  }

  @override
  String get description => 'Updates the version of the packages with '
      'changes within the project.';

  @override
  String get name => 'bump';

  void _logChanges(Map<String, PackageUpdate> versionBumps) {
    if (versionBumps.isEmpty) {
      stdout.writeln('No packages have been updated.');
      return;
    }
    final longestPackageNameLength = versionBumps.keys.map((e) => e.length).reduce(max);

    final buffer = StringBuffer(
      'The following packages have been updated:\n',
    );
    for (final update in versionBumps.values) {
      buffer.writeln(
        '${update.package.name.padRight(longestPackageNameLength)} : ${update.package.version} -> ${update.newVersion}${update.changelogPatch == null ? ' (No Changelog)' : ''}',
      );
    }

    stdout.write(buffer.toString());
  }

  @override
  FutureOr<void>? run() async {
    final scope = argResults!['scope'] as List<String>? ?? [];
    final ignore = argResults!['ignore'] as List<String>? ?? [];

    final filters = (
      scope: scope.map(Glob.new).toList(),
      ignore: ignore.map(Glob.new).toList(),
    );

    final versionBumps = await _computeBumps(filters);
    if (!(argResults!['dry-run'] as bool)) {
      await _applyBumps(versionBumps);
    }
    _logChanges(versionBumps);
  }

  Future<void> _applyBumps(Map<String, PackageUpdate> versionBumps) async {
    await Future.wait(
      versionBumps.values
          .expand(
            (update) => [
              update.changelogPatch?.run(),
              Future(
                () => update.package.updatePubspec(
                  update.newVersion,
                  dependencyChanges: update.dependencyChanges,
                ),
              ),
            ],
          )
          .nonNulls,
    );
  }

  Future<Map<String, PackageUpdate>> _computeBumps(
    PackageFilters filters,
  ) async {
    final versionBumps = <String, PackageUpdate>{};

    final workspace = await Workspace.find();

    await workspace.visitPackagesInDependencyOrder(filters: filters, (package) async {
      final update = await PackageUpdate.tryParse(package);
      if (update != null) {
        versionBumps[package.name] = update;
        // We continue to compute dependency changes in case, if any
      }
    });

    await workspace.visitPackagesInDependencyOrder(filters: filters, (package) async {
      var update = versionBumps[package.name];

      // Check if any of the dependencies has a version bump
      final dependencyChanges = workspace
          .dependenciesInWorkspace(package)
          .map((dependency) => versionBumps[dependency])
          .nonNulls
          .where((update) => needsDependencyBump(package, update))
          .toList();

      if (dependencyChanges.isEmpty) return;

      final lockedDependencyChanges = _findLockedDependencyChanges(package, dependencyChanges);
      final preReleaseFlag = dependencyChanges.any((e) => e.type.isPreRelease)
          ? dependencyChanges.map((e) => e.type.preReleaseFlag).nonNulls.firstOrNull
          : null;

      if (update == null) {
        // If a package has no updates but some dependency changes, we need to
        // bump the version of this package to match. But only do so if the
        // pubspec of the package has a version number.
        if (package.version == null) return;
        update = versionBumps[package.name] = PackageUpdate(
          package,
          lockedDependencyChanges ?? PackageUpdateType.dependencyChange(package.version!, preReleaseFlag),
        );

        if (package.changelog.existsSync()) {
          // Patch the changelog to add a new section for the new version
          update.changelogPatch = Patch(
            () async => package.changelog.writeAsString(
              '''
${update!.newVersionChangelogHeader}

${dependencyChanges.map((e) => '- `${e.package.name}` upgraded to `${e.newVersion}`').join('\n')}

${await package.changelog.readAsString()}''',
            ),
          );
        }
      }

      update.dependencyChanges.addAll(dependencyChanges);
    });

    return versionBumps;
  }
}

extension on Package {
  bool isLockedWithDependency(String dependencyName) {
    return isLockedWithDependencyReference(
          pubspec.dependencies[dependencyName],
        ) ||
        isLockedWithDependencyReference(
          pubspec.devDependencies[dependencyName],
        );
  }

  bool isLockedWithDependencyReference(
    Dependency? dependencyReference,
  ) {
    if (dependencyReference is! HostedDependency) return false;

    return dependencyReference.version is Version;
  }
}

PackageUpdateType? _findLockedDependencyChanges(
  Package package,
  List<PackageUpdate> dependencyChanges,
) {
  PackageUpdateType? result;
  for (final lockedDependency in dependencyChanges.where((e) => package.isLockedWithDependency(e.package.name))) {
    if (result != null && result != lockedDependency.type) return null;

    result = lockedDependency.type;
  }

  return result;
}

bool needsDependencyBump(
  Package package,
  PackageUpdate dependencyChange,
) {
  final dependency = package.pubspec.dependencies[dependencyChange.package.name] ??
      package.pubspec.devDependencies[dependencyChange.package.name];

  if (dependency is HostedDependency && dependency.version.allows(dependencyChange.newVersion)) {
    // No bump needed
    return false;
  }
  return true;
}

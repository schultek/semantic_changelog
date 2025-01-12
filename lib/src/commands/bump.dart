import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:collection/collection.dart';
import 'package:glob/glob.dart';
import 'package:melos/melos.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec/pubspec.dart';

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
    final longestPackageNameLength =
        versionBumps.keys.map((e) => e.length).reduce(max);

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

    final filters = PackageFilters(
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
          .whereNotNull(),
    );
  }

  Future<Map<String, PackageUpdate>> _computeBumps(
      PackageFilters filters) async {
    final versionBumps = <String, PackageUpdate>{};

    await visitPackagesInDependencyOrder(filters: filters, (package) async {
      var update = await PackageUpdate.tryParse(package);
      if (update != null) {
        versionBumps[package.name] = update;
        // We continue to compute dependency changes in case, if any
      }

      // Check if any of the dependencies has a version bump
      final dependencyChanges = package.dependenciesInWorkspace.values
          .map((dependency) => versionBumps[dependency.name])
          .whereNotNull()
          .toList();

      if (dependencyChanges.isEmpty) return;

      if (update == null) {
        // If a dependency has a version bump, we need to bump the version of this
        // package as well. But only do so if the pubspec of the package
        // has a version number.
        if (package.pubSpec.version == null) return;

        final dependencyUpdateType =
            _findDependencyUpdateType(package, dependencyChanges);

        if (dependencyUpdateType == null) {
          return;
        }

        update = versionBumps[package.name] = PackageUpdate(
          package,
          dependencyUpdateType,
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
  bool allowsDependencyVersion(String dependencyName, Version version) {
    return dependencyReferenceAllowsVersion(
          pubSpec.dependencies[dependencyName],
          version,
        ) &&
        dependencyReferenceAllowsVersion(
          pubSpec.devDependencies[dependencyName],
          version,
        );
  }

  bool dependencyReferenceAllowsVersion(
    DependencyReference? dependencyReference,
    Version version,
  ) {
    if (dependencyReference is! HostedReference) return true;

    return dependencyReference.versionConstraint.allows(version);
  }
}

PackageUpdateType? _findDependencyUpdateType(
  Package package,
  List<PackageUpdate> dependencyChanges,
) {
  PackageUpdateType? result;

  for (final dependency in dependencyChanges) {
    if (!package.allowsDependencyVersion(
        dependency.package.name, dependency.newVersion)) {
      result = PackageUpdateType.patch;
      break;
    }
  }

  return result;
}

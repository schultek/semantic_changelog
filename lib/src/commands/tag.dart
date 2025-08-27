import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:cli_util/cli_logging.dart';

import '../changelog.dart';
import '../packages.dart';
import '../prompts.dart';
import '../pub.dart';

/// The "tag" command.
class TagCommand extends Command<void> {
  TagCommand() {
    argParser.addFlag('force', abbr: 'f');
  }
  @override
  String get description => 'Git tag packages.';

  @override
  String get name => 'tag';

  final ansi = Ansi(Ansi.terminalSupportsAnsi);

  @override
  FutureOr<void>? run() async {
    final packagesToTag = await _computePackagesToTag();
    // Nothing to publish
    if (packagesToTag.isEmpty) return;

    _logPackagesToTag(packagesToTag);

    if (argResults!['force'] != true) {
      // The user aborted the tag
      if (!promptBool()) return;
    }

    await _tagPackages(packagesToTag);
  }

  Future<void> _tagPackages(List<_PackagePublish> packagesToPublish) async {
    for (final packageToPublish in packagesToPublish) {
      try {
        if (!await packageToPublish.package.hasTag()) {
          await packageToPublish.package.tag();
        }
        stdout.writeln(
          '${ansi.green}✓${ansi.noColor} ${packageToPublish.package.name}: ${packageToPublish.package.gitTagName}',
        );
      } catch (err) {
        stderr.writeln(
          '${ansi.red}✗${ansi.noColor} ${packageToPublish.package.name}\n\n'
          '$err',
        );
        return;
      }
    }
  }

  Future<List<_PackagePublish>> _computePackagesToTag() async {
    final packagesToPublish = <_PackagePublish>[];

    final workspace = await Workspace.find();

    await workspace.visitPackagesInDependencyOrder((package) async {
      if (!await _shouldTag(package)) return;

      final status = await _isAlreadyPublished(package);
      switch (status) {
        case _PublishReport.newVersion:
          packagesToPublish
              .add(_PackagePublish(package, isFirstPublish: false));
          break;
        case _PublishReport.firstTime:
          packagesToPublish.add(_PackagePublish(package, isFirstPublish: true));
          break;
        case _PublishReport.alreadyPublished:
          // Already on pub, nothing to do
          break;
      }
    });
    return packagesToPublish;
  }

  void _logPackagesToTag(List<_PackagePublish> packagesToPublish) {
    final packageWithLongestNameLength =
        packagesToPublish.map((e) => e.package.name.length).reduce(max);

    final buffer = StringBuffer('The following packages will be tagged:\n');

    for (final packageToPublish in packagesToPublish) {
      final version =
          '(${ansi.blue}${packageToPublish.package.version}${ansi.noColor})';

      buffer.writeln(
        '${packageToPublish.package.name.padRight(packageWithLongestNameLength)} : $version',
      );
    }
    stdout.write(buffer);
  }

  Future<bool> _shouldTag(Package package) async {
    if (package.pubspec.publishTo == 'none') return false;

    final update = await PackageUpdate.tryParse(package);
    // The package is work in progress, so we don't tag it.
    if (update != null) return false;

    return true;
  }

  Future<_PublishReport> _isAlreadyPublished(Package package) async {
    // If the package is already on pub, we don't publish it.
    final pubVersions = await fetchPubVersions(package.name);
    if (pubVersions == null) {
      return _PublishReport.firstTime;
    }

    if (pubVersions.hasVersion(package.version!)) {
      return _PublishReport.alreadyPublished;
    }

    return _PublishReport.newVersion;
  }
}

enum _PublishReport {
  /// This is the first time a package is published.
  firstTime,

  /// If the package version is already on pub.
  alreadyPublished,

  /// The package already exists on pub, but the local version is not present yet.
  newVersion,
}

class _PackagePublish {
  _PackagePublish(this.package, {required this.isFirstPublish});

  final bool isFirstPublish;
  final Package package;
}

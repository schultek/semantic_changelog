import 'package:args/command_runner.dart';
import 'package:semantic_changelog/src/commands/bump.dart';
import 'package:semantic_changelog/src/commands/publsh.dart';
import 'package:semantic_changelog/src/commands/tag.dart';

void main(List<String> args) => _SemanticChangelogCommandRunner().run(args);

class _SemanticChangelogCommandRunner extends CommandRunner<void> {
  _SemanticChangelogCommandRunner()
      : super(
          'semantic_changelog',
          'A command-line tool for versioning packages',
        ) {
    addCommand(BumpCommand());
    addCommand(PublishCommand());
    addCommand(TagCommand());
  }
}

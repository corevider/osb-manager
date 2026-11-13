# Instructions for AI coding agents

You are working on OSB Manager, a Windows (.NET, WebView2) and macOS (Swift, CEF) desktop app that runs several OpenSRO accounts side by side. Read [CONTRIBUTING.md](CONTRIBUTING.md) and follow it. The rules that agents break most often:

- **Never write comments in code.** No `//`, `/* */`, `///` or `#` comment lines in source files, including explanations of a fix. Put the explanation in the commit message body and the pull request description. Run the comment checks in CONTRIBUTING.md before you commit.
- **Keep the change small and on one topic.** Do not reformat, rename or refactor code the task does not need.
- **Do not change** the page scripts in `src/OsbManager/Browser/`, the page message format, the workflows in `.github/`, the update signing scripts or the update keys unless the issue asks for it.
- **Never send new data** off the user's computer, and never log names, passwords, chat, log text or file paths.
- **Never add secrets or real names.** Use made-up account, character and server names in tests and fixtures.
- **Run the tests** for the platform you changed (the commands are in CONTRIBUTING.md) and say in the pull request which ones you ran and on what OS and toolchain.
- **Commit messages** follow Conventional Commits: `<type>(<scope>): <subject>`, in English, imperative, no final period.
- **Do not bump versions** or write release notes.

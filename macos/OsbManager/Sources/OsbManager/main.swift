import OsbManagerApp

MainActor.assumeIsolated {
    OsbManagerApplication.run(arguments: Array(CommandLine.arguments.dropFirst()))
}

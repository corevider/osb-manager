import Foundation
import OsbManagerApp

let (configuration, applicationArguments) = E2EConfiguration.parse(Array(CommandLine.arguments.dropFirst()))

MainActor.assumeIsolated {
    OsbManagerApplication.run(arguments: applicationArguments) { app in
        await E2EDriver(app: app, config: configuration).run()
    }
}

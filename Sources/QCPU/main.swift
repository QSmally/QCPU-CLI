
let controller = CLIStateController()

if CLIStateController.arguments.count == 0 {
    CLIStateController.newline(CLIStateController.help)
}

guard let module = controller.module else {
    let input = CLIStateController.arguments.first!
    CLIStateController.terminate("Error: invalid command '\(input)'")
}

module.execute()

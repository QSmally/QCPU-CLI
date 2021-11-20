//
//  Tags.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 20/11/2021.
//

extension MemoryComponent {
    func tags() {
        for tag in file.prefix(while: { $0.hasPrefix("@") }) {
            var tagComponents = tag.components(separatedBy: .whitespaces)
            let identifier = tagComponents.removeFirst()

            if MemoryComponent.validTags.contains(identifier) {
                parseTag(identifier, tagComponents: tagComponents)
                tagAmount += 1
                continue
            }

            if !MemoryComponent.skipTaglikeNotation.contains(identifier) {
                CLIStateController.terminate("Parse error: invalid tag '\(identifier)' in file '\(name)'")
            } else {
                break
            }
        }

        file.removeFirst(tagAmount)
    }

    private func parseTag(_ tag: String, tagComponents: [String]) {
        print(tag)
    }
}

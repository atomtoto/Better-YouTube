import Foundation

let path = "/Users/Atom/Documents/GitHub/Better-YouTube/BetterYouTube/BetterYouTube/Views/Settings/AccountSection.swift"
var contents = try String(contentsOfFile: path, encoding: .utf8)

let target = """
        TextField("Click here to add YouTube OAuth client ID", text: $auth.clientId)
            .identifierField()
"""

let replacement = """
#if os(macOS)
        TextField("OAuth ID", text: $auth.clientId)
            .identifierField()
#else
        TextField("Click here to add YouTube OAuth client ID", text: $auth.clientId)
            .identifierField()
#endif
"""

contents = contents.replacingOccurrences(of: target, with: replacement)
try contents.write(toFile: path, atomically: true, encoding: .utf8)

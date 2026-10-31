import Foundation
import JTKit

extension Acknowledgement {
    /// Credit for Microsoft’s sign-in library, with its MIT license as
    /// published in the version JTKit pins (`MicrosoftSignIn.msalVersion`).
    /// Every app that links JTKitMSAL shows it in About.
    public static let msal = msal(summary: "Used to sign in to Entra ID and get access to Microsoft Graph.")

    /// The same credit with the app’s own sentence on what it uses MSAL for.
    public static func msal(summary: String) -> Acknowledgement {
        Acknowledgement(
            name: "Microsoft Authentication Library for iOS and macOS (MSAL)",
            author: "Microsoft Corporation",
            summary: summary,
            links: [
                AboutLink(
                    "AzureAD/microsoft-authentication-library-for-objc",
                    address: "https://github.com/AzureAD/microsoft-authentication-library-for-objc"
                ),
            ].compactMap { $0 },
            license: msalLicense
        )
    }

    /// MSAL’s `LICENSE` file at version 2.16.0, unchanged.
    public static let msalLicense = """
        MIT License

        Copyright (c) Microsoft Corporation

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """
}

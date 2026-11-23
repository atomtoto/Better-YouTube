import SwiftUI

/// A native feedback form, the same on iPhone, iPad and Mac.
struct FeedbackView: View {
    @Environment(\.openURL) private var openURL
    @State private var model = FeedbackModel()
    @State private var showingLinkError = false

    var body: some View {
        Form {
            Section {
                TextField("Your feedback", text: $model.message, axis: .vertical)
                    .lineLimit(5...10)
                    .accessibilityLabel("Feedback message")
                emailField
            } header: {
                Text("Feedback")
            } footer: {
                Text("Your message and optional email address are sent to Formspree. Include an email address if you would like a reply.")
            }
            .disabled(model.isSending)

            Section {
                Button {
                    Task { await model.send() }
                } label: {
                    if model.isSending {
                        ProgressView("Sending…")
                    } else {
                        Label("Send", systemImage: "paperplane")
                    }
                }
                .disabled(!model.canSend)

                if !model.isConfigured {
                    Text("Feedback sending is not configured yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                switch model.submissionState {
                case .idle:
                    EmptyView()
                case .success:
                    Label("Your feedback was accepted. Thank you!", systemImage: "checkmark.circle")
                case .failure:
                    Label("Could not send your feedback. Please try again.", systemImage: "exclamationmark.circle")
                }
            }

            Section {
                Button {
                    open(FeedbackLinks.githubIssue(message: model.message))
                } label: {
                    Label("Open a GitHub Issue", systemImage: "arrow.up.right.square")
                }
                .disabled(FeedbackLinks.githubIssue(message: model.message) == nil || model.isSending)

                if FeedbackLinks.githubIssue(message: model.message) == nil {
                    Text("Could not prepare the GitHub link for this message.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let address = FeedbackConfiguration.supportEmail {
                        open(FeedbackLinks.email(message: model.message, address: address))
                    }
                } label: {
                    Label("Send an Email", systemImage: "envelope")
                }
                .disabled(emailURL == nil || model.isSending)

                if emailURL == nil {
                    Text(FeedbackConfiguration.supportEmail == nil
                         ? "The contact email is not configured yet."
                         : "Could not prepare the email link for this message.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Other ways to send feedback")
            } footer: {
                Text("You can also open an issue on the app's public GitHub repository.")
            }
        }
        .settingsFormStyle()
        .warmPage()
        .navigationTitle("Feedback")
        .inlineNavigationBar()
        .navigationBarBackButtonHidden(model.isSending)
        .alert("Unable to Open Link", isPresented: $showingLinkError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Check that an app is available to open this link and try again.")
        }
    }

    private var emailURL: URL? {
        guard let address = FeedbackConfiguration.supportEmail else { return nil }
        return FeedbackLinks.email(message: model.message, address: address)
    }

    @ViewBuilder
    private var emailField: some View {
        #if os(iOS)
        TextField("Email address (optional)", text: $model.email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField("Email address (optional)", text: $model.email)
            .autocorrectionDisabled()
        #endif
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        openURL(url) { accepted in
            if !accepted { showingLinkError = true }
        }
    }
}

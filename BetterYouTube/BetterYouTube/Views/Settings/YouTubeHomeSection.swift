import SwiftUI

/// The one part of the app that steps outside the Data API, and the section says so plainly.
/// Nothing here is on until you sign in: without a session the Home screen doesn't even offer
/// the segment.
struct YouTubeHomeSection: View {
    @EnvironmentObject private var webSession: YouTubeWebSession
    @State private var showsSignIn = false

    var body: some View {
        Section {
            if webSession.isSignedIn {
                Label("Signed in to youtube.com", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Picker("Show as", selection: $webSession.rendering) {
                    ForEach(YouTubeWebSession.FeedRendering.allCases) { rendering in
                        Text(rendering.title).tag(rendering)
                    }
                }

                Button("Sign Out of youtube.com", role: .destructive) {
                    Task { await webSession.signOut() }
                }
            } else {
                Button {
                    showsSignIn = true
                } label: {
                    Label("Sign in to youtube.com", systemImage: "globe")
                }
            }
        } header: {
            Text("YouTube Home")
        } footer: {
            Text("""
            Your real home feed exists only on YouTube's own page: the Data API dropped the \
            personalized feed in 2016 and related videos in 2023. Signing in here opens \
            youtube.com in a web view and keeps its cookies on this device, apart from the Google \
            sign-in above — that one is a token scoped to the API, this one is a browser session. \
            The app reads the order of the videos on your home page and fetches everything it \
            shows about them through the API. That is outside what YouTube's terms allow apps to \
            do, it can break whenever the page changes, and it is your account that carries the \
            risk. Sign out here and the app forgets the session and the Home segment with it.
            """)
        }
        // The sheet belongs to the section that opens it. It used to hang off the whole screen,
        // which is how a sheet ends up outliving the thing that asked for it.
        .sheet(isPresented: $showsSignIn) {
            YouTubeSignInView()
        }
    }
}

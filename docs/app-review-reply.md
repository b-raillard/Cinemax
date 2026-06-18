# App Review — Resolution Center reply

Copy-paste into App Store Connect → Resolution Center, then resubmit.
Submission round addressing: Guideline 5.2.3 (Intellectual Property) and Guideline 1.5 (Safety / Support URL).

---

Hello,

Thank you for the review. We have addressed both points.

**Guideline 5.2.3 — Intellectual Property (offline downloads)**

We would like to clarify how Cinemax works, and we have updated the App Store
description to make this unambiguous.

Cinemax is a third-party *client* for Jellyfin (jellyfin.org), a free, open-source,
self-hosted media server. The app contains no media of its own and connects only to a
Jellyfin server that the user installs and runs themselves. Every movie, episode and
file shown in the app comes exclusively from the user's own personal server and their
own library.

The "offline" feature lets a user save videos *from their own Jellyfin server* onto
their device so they can watch their personal library without a network connection (for
example while travelling). It does not download, convert, or save media from any
third-party service or source (such as Apple Music, YouTube, SoundCloud, Vimeo, etc.).
There is no mechanism in the app to obtain content from anywhere other than the user's
own self-hosted server, which they fully control and authorize.

To remove any ambiguity, we have rewritten the relevant section of the description from
"Download movies, episodes, seasons or full series" to clearly state that the feature
provides offline access to the user's *own* library hosted on their *own* Jellyfin
server, with no downloading from third-party sources. We also added a closing sentence
stating that all videos come exclusively from the user's own server and that the app
neither contains content nor allows downloading from third-party sources.

This is the same model used by other self-hosted media-server clients on the App Store.

**Guideline 1.5 — Support URL**

We have created a dedicated support page with contact information, getting-started
guidance and a FAQ, and updated the Support URL in App Store Connect to:

https://b-raillard.github.io/Cinemax/support.html

The page provides a support email address, instructions for getting help and reporting
problems, and answers to common questions.

Thank you, and please let us know if anything else is needed.

Best regards,
Bastien Raillard

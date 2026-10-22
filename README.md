# Pulse-Casino
Is an app that lets you have a fun time choosing games with friends. Useful for people who are indecisive but like the gamboling feeling


PULSE CASINO
============

A casino-themed dashboard for your Steam games: playtime, achievements and
trophies, deals and price watches, what you're listening to, plus chips and
perks to win. It reads YOUR Steam account on YOUR PC. Nothing from the person
who sent you this is included, and nothing about you is sent to them.


WHAT YOU NEED
-------------
- Windows 10 or 11
- Steam installed and signed in on this PC
- Microsoft Edge WebView2 Runtime. Windows 11 already has it. Most Windows 10
  PCs do too; if Pulse never opens a window, get it from
  https://developer.microsoft.com/microsoft-edge/webview2/


HOW TO INSTALL
--------------
1. Before unzipping: right-click PulseCasino.zip > Properties. If there is an
   "Unblock" checkbox at the bottom, tick it and press OK.
2. Right-click the zip > Extract All... > Extract.
3. Open the extracted PulseCasino folder.
4. Double-click Install.cmd (it may show as just "Install").
   If a blue "Windows protected your PC" box appears, click More info >
   Run anyway. (Don't use right-click > "Run with PowerShell" on install.ps1:
   Windows blocks scripts by default, so that window just closes instantly.)
5. A blue window shows the progress, then Pulse opens by itself.
   A "Pulse Casino" icon is now on your desktop - use it from now on.

You can delete the zip and the extracted folder afterwards. Pulse lives in
  %LOCALAPPDATA%\PulseCasino


FULL ACHIEVEMENTS AND TROPHIES
------------------------------
Steam only shares achievement details if your game details are public:
  Steam > your name (top right) > View my profile > Edit Profile >
  Privacy Settings > set "My profile" and "Game details" to Public.
Your playtime still shows without this, but achievements and trophies will be
incomplete.


MOVIE THEATER (WATCH YOUR YOUTUBE INSIDE PULSE)
-----------------------------------------------
The Theater (the red "Theater" button in the lobby) shows your YouTube:
- Home: the newest videos from every channel you subscribe to
- Subscriptions: click a channel to see its latest uploads
- Playlists: your own playlists, with a "Play all" card
- Liked: videos you've liked
Click any video to play it on the big screen.

Google only lets apps read your YouTube if you create your own free "app" in
Google Cloud. That sounds scary but it's just a settings page, it's free, you
never enter a credit card, and nobody but you can use it. It takes about 15
minutes, once. Do it on the PC where Pulse is installed.

Pulse only asks Google for READ-ONLY access: it can see your subscriptions,
playlists and likes, but it can never post, comment, like, subscribe or delete
anything. Your sign-in is saved only on this PC, in
  %LOCALAPPDATA%\PulseCasino\app\youtube.json
Never send that file to anyone.

PART 1 - Create a Google Cloud project
  1. In your web browser, go to  https://console.cloud.google.com
     Sign in with the SAME Google account your YouTube is on.
  2. The first time, Google shows a welcome box: pick your country, tick the
     box to agree to the Terms of Service, and click "Agree and continue".
     If it offers a "free trial" with credits, you can ignore it (click
     Dismiss). You do NOT need a trial or billing for this.
  3. At the top left, next to the "Google Cloud" logo, click the project
     picker (it may say "Select a project"). In the box that opens, click
     "New project" (top right of the box).
  4. Project name: type anything, for example  Pulse Casino
     Leave "Location" as it is ("No organization") and click "Create".
  5. Wait a few seconds for the bell icon to say it's done, then click the
     project picker again and make sure your new project is selected. Every
     step below happens inside this project.

PART 2 - Turn on the YouTube Data API
  6. Go to
       https://console.cloud.google.com/apis/library/youtube.googleapis.com
     (or: menu at the top left > APIs & Services > Library, then search for
     "YouTube Data API v3" and click it).
  7. Check the project name at the top is your new project, then click the
     blue "Enable" button. When it's done the page says "API Enabled".

PART 3 - Set up the sign-in screen (Google calls it "Google Auth Platform")
  8. Go to  https://console.cloud.google.com/auth/overview
     (or: menu > APIs & Services > OAuth consent screen).
  9. Click "Get started".
 10. App Information:
       App name: Pulse Casino   (any name works; you'll see it when you sign in)
       User support email: pick your own email from the list
     Click "Next".
 11. Audience: choose "External" and click "Next".
     ("Internal" is only for work/school Google accounts.)
 12. Contact Information: type your own email address and click "Next".
 13. Finish: tick the box to agree to the Google API Services User Data
     Policy, click "Continue", then "Create".

PART 4 - Add yourself as a test user
 14. In the menu on the left, click "Audience".
 15. Scroll down to "Test users" and click "+ Add users".
 16. Type the email address of the Google account your YouTube is on, press
     Enter, then click "Save". You should see your email in the list.
     Only accounts on this list can sign in to your app, so it stays private.
     (Leave "Publishing status" on "Testing". Publishing needs your own
     website with a privacy policy, which you don't need.)

PART 5 - Create the keys Pulse needs
 17. In the menu on the left, click "Clients", then "+ Create client".
 18. Application type: choose "Desktop app" (NOT "Web application").
     Name: Pulse Theater   (any name works)
     Click "Create".
 19. A box pops up with your "Client ID" and "Client secret".
     IMPORTANT: keep this box open until step 22. Google only shows the
     secret once. (If you close it too early, just delete that client and
     make a new one.)
     Treat the secret like a password: don't post it or send it to anyone.

PART 6 - Connect Pulse
 20. Open Pulse and click the red "Theater" button in the lobby. You'll see
     a "Connect your YouTube" box.
 21. In the Google box from step 19, click the copy icon next to Client ID
     and paste it into Pulse's "Client ID" field. It ends in
     .apps.googleusercontent.com
 22. Do the same for the Client secret (it usually starts with GOCSPX-),
     then click "Save". Now you can close Google's box.
 23. Click "Sign in with Google". Google opens in your normal web browser.
 24. Choose the Google account you added as a test user in step 16.
 25. Google warns "Google hasn't verified this app". That's expected: it's
     YOUR app and Google hasn't reviewed it. Click "Continue" (on some
     screens: "Advanced" first, then "Go to Pulse Casino (unsafe)").
 26. Google lists what Pulse may do ("View your YouTube account"). Click
     "Continue" / "Allow".
 27. The browser says "Signed in to YouTube". Close that tab and go back to
     Pulse; within a few seconds the Theater shows your Home feed.

Good to know
- Because your app stays in "Testing", Google signs Pulse out about once a
  week. When the Theater shows "Sign in with Google" again, just repeat
  steps 23-27. Your keys are remembered.
- The first Home load takes a few seconds (Pulse checks each channel you
  subscribe to); after that it's saved for 15 minutes.
- Google gives every project a free daily allowance (10,000 "units"). Normal
  use is far below it. If the Theater says "quotaExceeded", wait until
  tomorrow.
- Some videos refuse to play outside youtube.com (the uploader turned off
  embedding, or it's age-restricted). YouTube then shows an error on the
  screen; watch those on youtube.com instead.
- Sign out: the "Sign out of YouTube" button at the top of the Theater.
  To remove the keys completely, quit Pulse and delete youtube.json (path
  above). You can also delete the whole project in Google Cloud.

Theater troubleshooting
- "That doesn't look like a Desktop app client ID and secret": you pasted
  something else, or picked "Web application" in step 18. Make a new client
  with type "Desktop app".
- Google shows "Error 403: access_denied": the account you chose isn't a
  test user. Redo step 16 with that exact email, or pick the right account.
- Google shows "Error 400: redirect_uri_mismatch": the client isn't a
  "Desktop app". Redo step 18.
- The Theater says "Couldn't load from YouTube: ... (403) Forbidden": the
  YouTube Data API is off. Redo step 7 (make sure the right project is
  selected), wait a minute, then press F5 in Pulse.
- Sign-in fails right after creating the client: Google can take a few
  minutes (rarely a few hours) to switch new keys on. Wait and try again.
- Sign-in finished in the browser but the Theater still says "Sign in":
  press F5 in Pulse.


EVERYDAY USE
------------
- Closing the window keeps Pulse running in the tray (near the clock) so it
  can count playtime and music. Right-click the tray chip icon for
  "Start with Windows" or "Quit Pulse".
- Sale prices use the region Steam detects from your internet connection.
  Price-watch search uses the country set in Windows (Settings > Time &
  language > Language & region > Country or region).


UPDATING
--------
Quit Pulse from the tray icon, then double-click Install.cmd from the new zip.
Your chips, history, settings and YouTube sign-in are kept.


UNINSTALLING
------------
Quit Pulse from the tray icon, delete the folder %LOCALAPPDATA%\PulseCasino
(paste that into the File Explorer address bar) and delete the desktop icon.


IF SOMETHING GOES WRONG
-----------------------
- The install window closes before you can read it: open the Start menu,
  type PowerShell, open it and paste (with your own folder):
    powershell -ExecutionPolicy RemoteSigned -File "C:\path\to\PulseCasino\install.ps1"
- Windows Security or Smart App Control blocks it: Pulse is a set of plain
  PowerShell scripts, not a signed app, so some PCs are stricter about it.
  Making sure you did step 1 (Unblock) usually helps.
- Errors are written to %LOCALAPPDATA%\PulseCasino\app\pulse.log

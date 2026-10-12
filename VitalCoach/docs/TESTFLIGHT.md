# Getting VitalCoach onto your iPhone with TestFlight (no Mac needed)

GitHub builds the app on one of its Macs, signs it with your Apple account, and uploads it to TestFlight. You install it from the TestFlight app on your iPhone. Every step below is done in a web browser, so Windows is fine.

> **Never paste keys or passwords into chat, email, or code.** They go only into GitHub's encrypted *Secrets* page (step 5).

Time: about 30–45 minutes the first time, plus up to 48 hours if you still need to join the Apple Developer Program.

---

## Step 1 — Join the Apple Developer Program (skip if you already have)

1. **Action:** enroll as an individual.
2. **Where:** https://developer.apple.com/programs/enroll/, using the Apple ID you'll use on your iPhone.
3. **Value needed:** $99/year payment.
4. **Verify:** https://developer.apple.com/account shows "Apple Developer Program" under Membership. Approval can take up to 48 hours.
5. **Next:** step 2.

## Step 2 — Note your Team ID and choose a bundle ID

1. **Where:** https://developer.apple.com/account → **Membership details**.
2. **Value needed:**
   - Copy the **Team ID**: 10 characters, like `AB12CD34EF`.
   - Choose a **bundle ID**, a reverse-domain name you'll keep forever, e.g. `com.yourname.vitalcoach`. Lowercase letters, numbers, dots.
3. **Verify:** both are written down somewhere private.
4. **Next:** step 3.

## Step 3 — Register the app ID with its capabilities

1. **Where:** https://developer.apple.com/account/resources/identifiers/list → **＋** → **App IDs** → **App** → Continue.
2. **Values needed:**
   - Description: `VitalCoach`.
   - Bundle ID: **Explicit**, then your bundle ID from step 2.
   - Under Capabilities, tick **HealthKit** and **Sign In with Apple**.
   - Continue → Register.
3. **Verify:** the identifier appears in the list with your bundle ID.
4. **Next:** step 4.

## Step 4 — Create the app in App Store Connect and an API key

**4a. App record**
1. **Where:** https://appstoreconnect.apple.com → **Apps** → **＋** → **New App**.
2. **Values needed:**
   - Platform: iOS.
   - Name: must be unique across the whole App Store. Try `VitalCoach`; if taken, use something like `VitalCoach Health Beta`. You can rename it later.
   - Primary language: English.
   - Bundle ID: pick yours from the dropdown.
   - SKU: anything, e.g. `vitalcoach-001`.
   - User access: Full.
3. **Verify:** the app page opens. Nothing on it needs filling in for TestFlight.

**4b. API key** (this lets GitHub sign and upload on your behalf)
1. **Where:** App Store Connect → **Users and Access** → **Integrations** tab → **App Store Connect API** → **Team Keys** → **＋** (Generate API Key). If asked, click *Request Access* first.
2. **Values needed:**
   - Name: `GitHub VitalCoach`.
   - Access: **Admin**. This is required so Apple can manage the signing certificate for you.
3. **Then:**
   - Click **Download** next to the new key. You get a file named `AuthKey_XXXXXXXXXX.p8`. **Apple lets you download it only once.**
   - Copy the **Key ID** shown in the table.
   - Copy the **Issuer ID** shown above the table.
4. **Verify:** you have the `.p8` file, the Key ID (10 characters) and the Issuer ID (a long ID with dashes).
5. **Next:** step 5.

## Step 5 — Add five secrets to GitHub

1. **Where:** https://github.com/ssb0004-byte/spy-options → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Repeat for each row:

| Secret name | Value |
|---|---|
| `APPLE_TEAM_ID` | Team ID from step 2 |
| `APP_BUNDLE_ID` | Bundle ID from step 2 |
| `ASC_KEY_ID` | Key ID from step 4b |
| `ASC_ISSUER_ID` | Issuer ID from step 4b |
| `ASC_PRIVATE_KEY` | Open the `.p8` file in **Notepad** and copy *everything*, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

2. **Verify:** the Secrets list shows all five names. GitHub never shows the values again, which is expected.
3. **Then:** move the `.p8` file somewhere safe, such as a password manager, and delete it from Downloads.
4. **Next:** step 6.

*Optional, later:* once Supabase is set up (SETUP.md steps 3–5), add two **Variables** (same page, *Variables* tab): `SUPABASE_HOST` and `SUPABASE_ANON_KEY`. Without them the app runs in "this iPhone only" mode, which is fine for a first look.

## Step 6 — Start a build

**Easiest:** tell Claude "build it". It edits `.github/testflight-request.txt` and pushes, which starts the "VitalCoach TestFlight" workflow. Builds use Xcode 26, which App Store Connect requires.

**Yourself:**
1. Go to https://github.com/ssb0004-byte/spy-options/releases → **Draft a new release**.
2. Click *Choose a tag* and type `vitalcoach-testflight-1` (increase the number each time) → **Create new tag**.
3. Set **Target** to the branch `claude/wizardly-heisenberg-2hzs5r`. Any title works.
4. Tick **Set as a pre-release** → **Publish release**.

**Verify:** the repo's **Actions** tab shows "VitalCoach TestFlight" running. It takes about 10–15 minutes and ends with a green tick and the message "Uploaded VitalCoach build N".

## Step 7 — Install on your iPhone

1. **Wait** for Apple's email saying the build has finished processing (usually 5–30 minutes after the green tick).
2. **Where:** App Store Connect → your app → **TestFlight** tab.
   - If a build shows **Missing Compliance**, click it and answer *None of the algorithms mentioned above*. The app only uses standard HTTPS.
   - Under **Internal Testing**, click **＋** to create a group (e.g. "Me"), add yourself, and add the build.
3. **On your iPhone:** install **TestFlight** from the App Store, open the invite email on the phone, and tap **View in TestFlight** → **Install**.
4. **Verify:** VitalCoach appears on your home screen. Choose **Try on this iPhone only** to explore.
5. **Next:** after each new build, TestFlight offers an update.

---

## Troubleshooting

The failed run's page has a **testflight-logs** download. Common messages:

| Message | Fix |
|---|---|
| `Missing repository secrets: …` | Add the named secret(s) in step 5. Names must match exactly. |
| `ASC_PRIVATE_KEY must be the full text…` | Re-copy the whole `.p8` file, including the BEGIN/END lines. |
| `No profiles for 'com.…' were found` or `Cloud signing permission error` | The API key needs **Admin** access (step 4b), and the bundle ID must match step 3 exactly. |
| `No suitable application records were found` | Create the app record (step 4a) with the same bundle ID. |
| `The bundle version must be higher than the previously uploaded version` | Happens only if you uploaded from a Mac with a higher build number. Re-run; each GitHub run uses a higher number automatically. |
| `Invalid entitlements` / HealthKit capability | Make sure HealthKit and Sign In with Apple are ticked on the App ID (step 3). |

The first run may need one round of fixes, because signing can't be fully tested until real credentials exist. Send Claude the error line from the log; never send the key.

## Safety notes

- The API key has Admin access to your App Store Connect account. Keep it only in GitHub Secrets. If it ever leaks, revoke it under Users and Access → Integrations and make a new one.
- Anyone with *write* access to this GitHub repository can run workflows that use these secrets, so don't add collaborators you don't trust.
- Builds are marked **internal testing only**, so they go only to people on your App Store Connect team and never to the public.
- Signing certificates are managed by Apple in the cloud, so nothing needs copying to the build machine. If you later see extra "Created via API" development certificates under Certificates on developer.apple.com, they can be revoked safely.

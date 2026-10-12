# Founder setup guide

You can run the app **before** doing any of this: on the sign-in screen choose **Try on this iPhone only**. Data then stays on that device only. The steps below turn on Sign in with Apple and cloud backup.

> Never paste secret keys into chat, email, or Git. The only Supabase values that go into the app are the **project host** and the **anon (public) key**.

---

## 1. Run the app on your Mac

1. **Action:** install Xcode (16 or newer) from the Mac App Store.
2. **Where:** in Terminal, run:
   ```
   git clone <your repo URL> && cd spy-options/VitalCoach && open VitalCoach.xcodeproj
   ```
3. **Value needed:** none yet.
4. **Verify:** in Xcode, choose an iPhone simulator at the top and press ▶︎. The VitalCoach sign-in screen appears.
5. **Next:** to run on your own iPhone, complete step 2.

If you add or remove Swift files, regenerate the project with `brew install xcodegen && xcodegen generate` inside `VitalCoach/`.

## 2. Apple Developer settings (needed for an iPhone, Sign in with Apple and HealthKit)

1. **Action:** copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`. The copy is git-ignored.
2. **Where:** open the copy in any text editor.
3. **Values needed:**
   - `VC_DEVELOPMENT_TEAM`: your Team ID, from developer.apple.com → Account → Membership details.
   - `VC_BUNDLE_ID`: a unique ID you own, e.g. `com.yourname.vitalcoach`.
4. **Then**, in Xcode → target **VitalCoach** → **Signing & Capabilities**, confirm these capabilities appear: **Sign in with Apple**, **HealthKit**, and HealthKit's **Background Delivery**. Xcode registers them automatically when signing is set to Automatic.
5. **Verify:** connect your iPhone, select it, press ▶︎. The app installs.
6. **Next:** create the backend (step 3).

## 3. Create the Supabase backend (free tier)

1. **Action:** create a free account at supabase.com and a **New project** in a region near you. Store the database password in a password manager.
2. **Where:** Supabase dashboard → **SQL Editor** → New query.
3. **Value needed:** paste the entire contents of `supabase/migrations/20261012000001_phase1_core.sql` and click **Run**.
4. **Verify:** **Table Editor** lists 12 tables (user_profiles … audit_events). Open any of them: each shows "RLS enabled".
5. **Next:** connect Apple sign-in (step 4).

*Alternative for later:* install the Supabase CLI and run `supabase link` then `supabase db push`, so future migrations are applied from version control.

## 4. Enable Sign in with Apple in Supabase

1. **Action:** Supabase dashboard → **Authentication → Sign In / Providers → Apple** → enable.
2. **Value needed:** under *Client IDs*, enter your app's bundle ID (the `VC_BUNDLE_ID` value). For native iOS sign-in, no secret key is required.
3. **Verify:** the Apple provider shows as Enabled.
4. **Next:** point the app at your project (step 5).

## 5. Connect the app to Supabase

1. **Where:** Supabase → **Project Settings → API** (or **API Keys**).
2. **Values needed:** add these to `Config/Secrets.xcconfig`:
   - `SUPABASE_HOST`: the project URL **without** `https://`, e.g. `abcd1234.supabase.co`.
   - `SUPABASE_ANON_KEY`: the **anon / publishable** key. It is public by design.
   - **Never** use the `service_role` / secret key here.
3. **Verify:** run the app. The sign-in screen now shows **Sign in with Apple**. Sign in, finish onboarding, and turn on **Back up and sync**. In Supabase → Table Editor → `user_goals`, your goals appear.
4. **Next:** deploy account deletion (step 6).

## 6. Deploy the account-deletion function

1. **Action:** install the Supabase CLI (`brew install supabase/tap/supabase`), then inside `VitalCoach/` run:
   ```
   supabase login
   supabase link --project-ref <your project ref>
   supabase functions deploy delete-account
   ```
2. **Value needed:** your project ref, the part before `.supabase.co`. The function reads the service-role key from Supabase's built-in server secrets, so you don't provide it.
3. **Verify:** in a test account, Profile → Delete account. The user disappears from Supabase → Authentication → Users, and their rows disappear from the tables.
4. **Next:** set up spending limits (step 7).

## 7. Cost safety

- Supabase free plan: no card is required and it cannot bill you. Free projects pause after about a week of inactivity; open the dashboard to resume.
- When you upgrade to Pro, keep **Spend Cap** on (Organization → Billing).

## Running the automated tests

- **Mac:** in Xcode press ⌘U. This runs VitalCore tests and app tests.
- **Any machine with Docker:** `scripts/swift-in-docker.sh test`.
- **Database tests** (Postgres + Docker): `supabase/tests/run.sh`.
- GitHub Actions runs all of these on every push that touches `VitalCoach/`.

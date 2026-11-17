# Setting up "Sign in with Google / Microsoft"

Lumen Mail has no company behind it to register with Google or Microsoft, so
you register your own copy once. It's free. Each registration covers **all**
your accounts with that provider, so you do Google once and Microsoft once.

When to use which:

| Account | Use |
|---|---|
| Personal Gmail | An **app password** is simplest. Google sign-in also works. |
| University Google account (webmail looks like Gmail) | **Sign in with Google** |
| University Microsoft 365 account (webmail looks like Outlook) | **Sign in with Microsoft** |
| Outlook.com / Hotmail | **Sign in with Microsoft** |
| iCloud, Yahoo, Fastmail | **App password** |

---

## Google (about 10 minutes)

1. Open <https://console.cloud.google.com> and sign in with any Google account
   (your personal one is fine).
2. Click the project picker at the top → **New project** → name it
   "Lumen Mail" → **Create**, then select it.
3. **APIs & Services → Library** → search "Gmail API" → **Enable**.
4. **APIs & Services → OAuth consent screen** (also called "Google Auth
   Platform"):
   - User type / Audience: **External**
   - App name: `Lumen Mail`, support email: your email, developer contact:
     your email → Save.
   - **Audience → Test users → Add users**: add **every Google address you
     will sign in with** (personal and university). While the app is in
     "Testing" mode, only these addresses can sign in. That's fine for
     personal use.
5. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   - Application type: **Desktop app**, name: `Lumen Mail` → **Create**.
6. Copy the **Client ID** and **Client secret** into Lumen Mail (Add account →
   Sign in with Google, or Settings → Sign-in apps).

For desktop apps, Google's "client secret" isn't really secret, but keep it
to yourself anyway.

**Good to know**
- Google shows an "unverified app" warning on the sign-in page. That's
  expected for your own registration: click **Continue**.
- In Testing mode, Google may ask you to sign in again about once a week.
  To avoid that, you can **Publish** the app on the consent screen page. It
  still works for you without going through Google's verification.
- **University Google accounts:** if you see "access blocked" or "admin
  policy", your university only allows apps it has approved. Ask IT, or keep
  using their webmail for that account.

## Microsoft (about 10 minutes)

1. Open <https://entra.microsoft.com> and sign in with a **personal**
   Microsoft account (Outlook/Hotmail; create one if needed). Using a
   university account here often fails because universities restrict app
   registrations.
2. **Applications → App registrations → New registration**
   - Name: `Lumen Mail`
   - Supported account types: **Accounts in any organizational directory and
     personal Microsoft accounts**
   - Redirect URI: platform **Public client/native (mobile & desktop)**,
     value `http://localhost`
   - **Register**
3. **API permissions → Add a permission → APIs my organization uses** →
   search **Office 365 Exchange Online** → **Delegated permissions** → tick
   `IMAP.AccessAsUser.All` and `SMTP.Send` → **Add permissions**.
   (`offline_access`, `openid`, `email` and `profile` are requested
   automatically.)
4. **Authentication** → under *Advanced settings*, set **Allow public client
   flows** to **Yes** → Save.
5. Copy the **Application (client) ID** from **Overview** into Lumen Mail.
   No secret is needed.

**Good to know**
- **"Need admin approval":** your university requires IT to approve new
  apps. Send them the Application (client) ID and ask them to allow it for
  IMAP and SMTP, or use Outlook/Apple Mail for that account.
- **Signed in, but the connection fails:** some universities turn off IMAP or
  "SMTP AUTH" for student mailboxes. Reading may work while sending doesn't.
  Only university IT can change this.

---

## Privacy

Sign-in happens in your own browser, so Lumen Mail never sees your password.
Google or Microsoft hands back a key that only allows email access. It's
stored in your Mac's Keychain and refreshed automatically. Removing an account
in Lumen Mail deletes its key. To revoke access entirely, use
<https://myaccount.google.com/permissions> or
<https://account.microsoft.com/privacy/app-access>.

# EarnyBee 🐝

An automation and data platform powered by **Supabase** and **Apify**.

## 🛠️ Tech Stack & Integrations

- **Database & Auth:** [Supabase](https://supabase.com/)
- **Scraping & Automation:** [Apify](https://apify.com/)
- **Version Control:** [GitHub](https://github.com/Bniuka/EarnyBee)

---

## 🚀 Getting Started

### 1. Clone the repository
```bash
git clone https://github.com/Bniuka/EarnyBee.git
cd EarnyBee
```

### 2. Configure Environment Variables
Copy `.env.example` to `.env` and fill in your keys:
```bash
cp .env.example .env
```

| Variable | Description |
|---|---|
| `SUPABASE_URL` | Your Supabase project URL |
| `SUPABASE_ANON_KEY` | Supabase publishable / anon public key |
| `APIFY_API_TOKEN` | Apify personal API token |

---

## 🔒 Security
- `.env` is explicitly ignored by `.gitignore` to prevent secret leaks.
- Always use `.env.example` for referencing required environment variables.

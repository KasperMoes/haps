# Backend (Supabase-projekt "Haps", gfuobktfdgcxapvrgsny)

Tabeller i `public`:
- **profiles** – brugernavn, navn, profilbillede (oprettes automatisk ved tilmelding).
- **friendships** – venneanmodninger (`pending`) og venskaber (`accepted`).
- **meals** – aftensmad: titel, bedømmelse (`anbefales` / `spiseligt`), tekst, billede.
- **comments** – kommentarer på aftensmad.
- **haps** – én række pr. person, der kunne hapse en aftensmad.
- **notifications** – fanen "Haps" (haps, kommentarer, venneanmodninger). Laves af databasen selv.
- **push_subscriptions** – telefoner, der vil have push-beskeder.

Adgang: man ser kun egen og venners aftensmad, haps og kommentarer.
Billeder: privat bucket `photos/<bruger-id>/…` (venner kan se), offentlig bucket `avatars`.
Push: trigger på `notifications` og `meals` kalder edge function `push` (functions/push/index.ts).
Hemmelige nøgler ligger i Supabase Vault, ikke her.

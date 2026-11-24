# Iguana documentation

The documentation site for Iguana, built with [Astro Starlight](https://starlight.astro.build/).

```sh
npm install
npm run dev        # local preview with live reload
npm run build      # builds to dist/ and checks every internal link and anchor
npm run check      # checks the reference pages against ../Sources
npm run schema     # copies the JSON Schema out of ../Sources into public/schema/
```

Pages live in `src/content/docs/`. The sidebar is defined in `astro.config.mjs`, and the theme
in `src/styles/iguana.css`.

`npm run check` reads the Swift source and fails if a command, config key, default value,
allowed range, default shortcut or key name is missing from the reference pages or differs
from the source. Run it whenever `Sources/` changes.

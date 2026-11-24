import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

export const collections = {
	docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
	// Starlight looks for interface text here. The file in src/content/i18n/ overrides nothing;
	// it is there so the build does not warn about an empty collection.
	i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};

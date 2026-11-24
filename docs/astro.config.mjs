// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://iguana.onlychan.xyz',
	integrations: [
		starlight({
			title: 'Iguana',
			description:
				'Iguana is a tiling window manager for macOS. It arranges the windows on each desktop and leaves every one of them where you can see it.',
			logo: {
				light: './src/assets/logo-light.svg',
				dark: './src/assets/logo-dark.svg',
				alt: '',
			},
			favicon: '/favicon.svg',
			// The picture a link to any page shows when it is shared.
			head: [
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://iguana.onlychan.xyz/og.png' } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://iguana.onlychan.xyz/og.png' } },
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#061a14' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' } },
			],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/Chandram-Dutta/iguana' }],
			editLink: { baseUrl: 'https://github.com/Chandram-Dutta/iguana/edit/main/docs/' },
			customCss: ['./src/styles/iguana.css'],
			lastUpdated: false,
			// src/content/docs/404.md is the not-found page, so Starlight's built-in one is not needed.
			disable404Route: true,
			sidebar: [
				{
					label: 'Start here',
					items: [
						{ label: 'Why Iguana', slug: 'start/why-iguana' },
						{ label: 'Install', slug: 'start/install' },
						{ label: 'First ten minutes', slug: 'start/first-ten-minutes' },
					],
				},
				{
					label: 'Guides',
					items: [
						{ label: 'How tiling works', slug: 'guides/how-tiling-works' },
						{ label: 'Desktops and displays', slug: 'guides/desktops-and-displays' },
						{ label: 'Floating windows and rules', slug: 'guides/floating-windows' },
						{
							label: 'Stage Manager, fullscreen and tabs',
							slug: 'guides/stage-manager-fullscreen-tabs',
						},
						{ label: 'The settings window', slug: 'guides/settings-window' },
						{ label: 'Animation', slug: 'guides/animation' },
						{ label: 'Customising shortcuts', slug: 'guides/shortcuts' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'Configuration', slug: 'reference/configuration' },
						{ label: 'Commands', slug: 'reference/commands' },
						{ label: 'Default shortcuts', slug: 'reference/default-shortcuts' },
						{ label: 'Command line', slug: 'reference/command-line' },
						{ label: 'Key names', slug: 'reference/key-names' },
					],
				},
				{
					label: 'Help',
					items: [
						{ label: 'Troubleshooting', slug: 'help/troubleshooting' },
						{ label: 'Limitations', slug: 'help/limitations' },
						{ label: 'Under the hood', slug: 'help/under-the-hood' },
						{ label: 'FAQ', slug: 'help/faq' },
					],
				},
			],
		}),
	],
});

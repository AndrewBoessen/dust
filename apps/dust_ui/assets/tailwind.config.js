const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/dust_ui.ex",
    "../lib/dust_ui/**/*.{ex,heex}",
  ],
  theme: {
    extend: {
      colors: {
        brand: "#18181b",
      },
    },
  },
  plugins: [
    plugin(({ addVariant }) => addVariant("phx-no-feedback", [".phx-no-feedback&", ".phx-no-feedback &"])),
    plugin(({ addVariant }) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embed Heroicons (https://heroicons.com) as `hero-*` mask utilities.
    // Vendored via the `heroicons` mix dep (deps/heroicons/optimized).
    plugin(function ({ matchComponents, theme }) {
      const iconsDir = path.join(__dirname, "../../../deps/heroicons/optimized")
      const variants = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"],
      ]
      const values = {}
      variants.forEach(([suffix, dir]) => {
        const fullDir = path.join(iconsDir, dir)
        if (!fs.existsSync(fullDir)) return
        fs.readdirSync(fullDir).forEach((file) => {
          const name = path.basename(file, ".svg") + suffix
          values[name] = { name, fullPath: path.join(fullDir, file) }
        })
      })
      matchComponents(
        {
          hero: ({ name, fullPath }) => {
            const content = fs
              .readFileSync(fullPath)
              .toString()
              .replace(/\r?\n|\r/g, "")
            let size = theme("spacing.6")
            if (name.endsWith("-mini")) size = theme("spacing.5")
            if (name.endsWith("-micro")) size = theme("spacing.4")
            return {
              [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
              "-webkit-mask": `var(--hero-${name})`,
              mask: `var(--hero-${name})`,
              "mask-repeat": "no-repeat",
              "background-color": "currentColor",
              "vertical-align": "middle",
              display: "inline-block",
              width: size,
              height: size,
            }
          },
        },
        { values }
      )
    }),
  ],
}

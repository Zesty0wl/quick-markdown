// Source of the Quick Markdown wrapper bundled at the end of
// QuickMarkdown/WebAssets/mermaid/mermaid.js (Mermaid 11.17.2).
//
// Build (from this folder, with mermaid@11.17.2 and esbuild@0.28.2 installed):
//   npx esbuild mermaid.js --bundle --format=iife --target=safari15 \
//     --outfile=../../QuickMarkdown/WebAssets/mermaid/mermaid.js \
//     --legal-comments=linked --minify
//
// 1.0.10 changes, applied to the bundled file by hand as well:
// `renderAll` queues repeat runs instead of returning the first one, so a
// page updated in place can render newly added diagrams, and failed blocks
// are marked so a repeat run doesn't add a second error message.
// Pie charts use GitHub's palette (`themeVariables`).
import mermaid from 'mermaid'
import './mermaid.css'

const PIE_DARK = { pie1: "#58a6ff", pie2: "#bc8cff", pie3: "#3fb950", pie4: "#d29922", pie5: "#f778ba", pie6: "#39c5cf", pie7: "#ff7b72", pie8: "#a5d6ff", pieSectionTextColor: "#0d1117", pieStrokeColor: "#0d1117", pieOuterStrokeColor: "#0d1117", pieOpacity: "1", pieLegendTextColor: "#e6edf3", pieTitleTextColor: "#e6edf3" }
const PIE_LIGHT = { pie1: "#0969da", pie2: "#8250df", pie3: "#1a7f37", pie4: "#bf8700", pie5: "#bf3989", pie6: "#1b7c83", pie7: "#cf222e", pie8: "#54aeff", pieSectionTextColor: "#ffffff", pieStrokeColor: "#ffffff", pieOuterStrokeColor: "#ffffff", pieOpacity: "1", pieLegendTextColor: "#1f2328", pieTitleTextColor: "#1f2328" }

let nextDiagramID = 0
let rendering = null

async function renderDiagrams({ dark = false } = {}) {
  const blocks = Array.from(
    document.querySelectorAll('pre > code.language-mermaid:not(.qm-mermaid-failed)')
  )
  if (!blocks.length) return { rendered: 0, failed: 0 }

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    suppressErrorRendering: true,
    theme: dark ? 'dark' : 'neutral',
    // Both themes derive pie slices from near-grey base colours; use
    // GitHub's palette so slices are distinct.
    themeVariables: dark ? PIE_DARK : PIE_LIGHT,
    fontFamily: '-apple-system, BlinkMacSystemFont, Helvetica, sans-serif',
    maxTextSize: 50000,
    maxEdges: 500,
    flowchart: { htmlLabels: false },
  })

  let rendered = 0
  let failed = 0
  for (const code of blocks) {
    const source = code.textContent
    const container = code.parentElement
    try {
      const { svg } = await mermaid.render(`qm-mermaid-${++nextDiagramID}`, source)
      const diagram = document.createElement('div')
      diagram.className = 'qm-mermaid'
      diagram.setAttribute('role', 'figure')
      diagram.setAttribute('aria-label', 'Mermaid diagram')
      diagram.innerHTML = svg
      container.replaceWith(diagram)
      rendered += 1
    } catch {
      code.classList.add('qm-mermaid-failed')
      const message = document.createElement('p')
      message.className = 'qm-mermaid-error'
      message.setAttribute('role', 'status')
      message.textContent = 'Unable to render this Mermaid diagram. Check its syntax in Source.'
      container.before(message)
      failed += 1
    }
  }
  return { rendered, failed }
}

window.QuickMarkdownMermaid = {
  renderAll(options) {
    rendering = (rendering ?? Promise.resolve())
      .catch(() => {})
      .then(() => renderDiagrams(options))
    return rendering
  },
}

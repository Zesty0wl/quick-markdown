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
import mermaid from 'mermaid'
import './mermaid.css'

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

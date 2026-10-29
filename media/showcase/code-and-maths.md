# Code and maths, properly typeset

Syntax highlighting for 193 languages, with GitHub's own colours.

```swift
struct Document: Identifiable {
    let id = UUID()
    var title: String
    var words: Int { body.split(whereSeparator: \.isWhitespace).count }
    private(set) var body: String
}
```

```python
def fibonacci(n: int) -> list[int]:
    """Return the first n Fibonacci numbers."""
    seq = [0, 1]
    while len(seq) < n:
        seq.append(seq[-1] + seq[-2])
    return seq[:n]
```

```rust
fn main() {
    let total: u64 = (1..=100).filter(|n| n % 3 == 0).sum();
    println!("Sum of multiples of 3: {total}");
}
```

```typescript
interface Release {
  version: `${number}.${number}.${number}`;
  notarized: boolean;
}

const latest: Release = { version: "1.0.11", notarized: true };
```

```diff
- let html = renderer.render(markdown)
+ let html = renderer.render(markdown, theme: .nightSky)
```

```bash
# Watch the file your agent is writing
open -a "Quick Markdown" plan.md && claude "Draft the migration plan in plan.md"
```

## Equations, rendered by KaTeX

Euler's identity $e^{i\pi} + 1 = 0$ sits inline, and display maths gets room to breathe:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
\qquad
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
$$

$$
\mathbf{A}\mathbf{x} = \begin{pmatrix} 2 & -1 \\ 1 & 3 \end{pmatrix}
\begin{pmatrix} x_1 \\ x_2 \end{pmatrix}
= \begin{pmatrix} 4 \\ 9 \end{pmatrix}
$$

GitHub's ` ```math ` blocks, `` $`…`$ `` and LaTeX `\(…\)` / `\[…\]` all work too.

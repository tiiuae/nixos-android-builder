// Tables: prevent overflow, enable word wrap, keep together
#set table(
  stroke: 0.5pt + luma(180),
  inset: 6pt,
)
#show figure.where(kind: table): set block(breakable: false)

// Definition lists: consistent spacing between items
#show terms.item: it => {
  v(1.2em)
  line(length: 100%, stroke: 0.3pt + luma(200))
  v(0.4em)
  it
  v(0.3em)
}

// Code blocks: smaller font, prevent overflow
#show raw.where(block: true): set text(size: 8pt)
#show raw.where(block: false): set text(size: 9pt)

// Table cells: allow word wrap
#show table.cell: set par(justify: false)
#show table.cell: set text(size: 9pt)

// Prevent orphan/widow lines
#set par(leading: 0.65em)

import type { ReactNode } from "react";

/**
 * The same header on every screen: a serif title, one line of context, and the
 * screen's actions on the right. A page merged from several screens has this
 * once; what were their own titles become section headings (.h2) under it.
 */
export function PageHead({
  title,
  context,
  actions,
  toc,
}: {
  title: string;
  context?: ReactNode;
  actions?: ReactNode;
  /** Jump links to the page's sections, as [anchor, label]. */
  toc?: [string, string][];
}) {
  return (
    <>
      <header className="page-head">
        <div>
          <h1 className="h1">{title}</h1>
          {context && <p className="sub">{context}</p>}
        </div>
        {actions && (
          <div className="row2 no-print" style={{ gap: 8 }}>
            {actions}
          </div>
        )}
      </header>
      {toc && toc.length > 1 ? (
        <nav className="page-toc no-print" aria-label="On this page">
          {toc.map(([anchor, label]) => (
            <a key={anchor} href={`#${anchor}`}>
              {label}
            </a>
          ))}
        </nav>
      ) : (
        <div style={{ marginBottom: 12 }} />
      )}
    </>
  );
}

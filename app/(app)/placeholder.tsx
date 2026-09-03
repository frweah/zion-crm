/**
 * Stand-in for a screen that has not been ported yet.
 *
 * The navigation is role-correct from Phase 1 so the shape of the app is real
 * and each role sees exactly the screens it should. Each of these is replaced
 * in Phase 2 by its prototype component.
 */
export function Placeholder({ title, note }: { title: string; note?: string }) {
  return (
    <>
      <h1 className="h1">{title}</h1>
      <p className="sub">{note ?? "Ported from the prototype in Phase 2."}</p>
      <div className="card">
        <h3>Not built yet</h3>
        <p className="sub" style={{ margin: 0 }}>
          Phase 1 covers the database, roles, row-level security and the invite flow. This screen
          arrives with the rest of Phase 2.
        </p>
      </div>
    </>
  );
}

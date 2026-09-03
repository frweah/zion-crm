import { ORG } from "@/lib/roles";

export default function NoAccessPage() {
  return (
    <main className="centre">
      <div className="panel">
        <h1>No access</h1>
        <p className="sub">
          You are signed in, but this address has no active staff account in the CRM. If your
          account was recently closed, that is expected. Otherwise contact the administrator at{" "}
          {ORG.email}.
        </p>
        <form action="/auth/signout" method="post">
          <button className="btn ghost" type="submit" style={{ width: "100%" }}>
            Sign out
          </button>
        </form>
      </div>
    </main>
  );
}

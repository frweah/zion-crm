"use client";

import { useState, useActionState } from "react";
import { signW4, type PaperworkState } from "./actions";
import { W4_FILING_STATUSES, W4_CREDITS } from "@/lib/irs-forms-shared";

const initial: PaperworkState = { error: null, ok: null };

const usd = (n: number) => `$${n.toLocaleString("en-US")}`;

/**
 * Form W-4, Employee's Withholding Certificate.
 *
 * Step 3 asks for amounts, not counts — "multiply the number of qualifying
 * children by $2,200". Asking for the count and doing the multiplication is
 * both easier to answer and harder to get wrong, and the working is shown so
 * the figure being used is visible before anyone signs. The multipliers change
 * with the law, so they live in one place beside the form year.
 *
 * The multiple jobs worksheet on page 3 and the deductions worksheet on page 4
 * are not reproduced. They are scratch paper for arriving at a number, the IRS
 * does not want them back, and the estimator on irs.gov does the same job
 * better. Whatever they produce is entered in Step 4.
 */
export function W4Form({ defaultName }: { defaultName: string }) {
  const [state, action, pending] = useActionState(signW4, initial);

  const [first, ...rest] = defaultName.split(" ");
  const [firstName, setFirstName] = useState(first ?? "");
  const [lastName, setLastName] = useState(rest.join(" "));
  const [exempt, setExempt] = useState(false);
  const [children, setChildren] = useState(0);
  const [dependents, setDependents] = useState(0);

  const childAmount = children * W4_CREDITS.perQualifyingChild;
  const dependentAmount = dependents * W4_CREDITS.perOtherDependent;

  return (
    <div className="card">
      <h3>Form W-4 — Employee&apos;s Withholding Certificate</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        This tells payroll how much federal income tax to withhold from your pay. You can complete
        a new one whenever your circumstances change, and it takes effect from the next payroll
        run.
      </p>

      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      <form action={action}>
        <h3 style={{ marginTop: 20 }}>Step 1 · Who you are</h3>
        <div className="row2">
          <label className="field">
            First name and middle initial
            <input
              name="first_name"
              value={firstName}
              onChange={(e) => setFirstName(e.target.value)}
              required
            />
          </label>
          <label className="field">
            Last name
            <input
              name="last_name"
              value={lastName}
              onChange={(e) => setLastName(e.target.value)}
              required
            />
          </label>
        </div>
        <label className="field">
          Address
          <input name="address" required />
        </label>
        <div className="row2">
          <label className="field" style={{ flex: 2 }}>
            City or town, state, and ZIP code
            <input name="city_state_zip" required />
          </label>
          <label className="field">
            Social security number
            <input name="ssn" required inputMode="numeric" autoComplete="off" placeholder="000-00-0000" />
          </label>
        </div>
        <p className="lock" style={{ marginTop: 0 }}>
          Use the name as it appears on your social security card. If they differ you may not get
          credit for your earnings — the SSA can correct it on 800-772-1213. Your number is
          encrypted the moment you sign, and only the administrator can open the completed form.
        </p>

        <label className="field">
          Filing status
          <select name="filing_status" required defaultValue={W4_FILING_STATUSES[0]}>
            {W4_FILING_STATUSES.map((s) => (
              <option key={s} value={s}>
                {s}
              </option>
            ))}
          </select>
          <span className="lock">
            Head of household applies only if you are unmarried and pay more than half the cost of
            keeping up a home for yourself and a qualifying individual.
          </span>
        </label>

        <div className="alert" style={{ marginTop: 18 }}>
          <label style={{ fontSize: 13, display: "block" }}>
            <input
              type="checkbox"
              name="exempt"
              checked={exempt}
              onChange={(e) => setExempt(e.target.checked)}
              style={{ width: "auto", marginRight: 8 }}
            />
            I claim exemption from withholding for {W4_CREDITS.formYear}
          </label>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            Only if both are true: you had no federal income tax liability last year and had all of
            it refunded, and you expect none this year. Claiming this wrongly leaves you with a
            bill and possibly a penalty. It also expires — a new form is due each February.
            Everything below is left blank when you claim it.
          </p>
        </div>

        {!exempt && (
          <>
            <h3 style={{ marginTop: 20 }}>Step 2 · More than one job</h3>
            <label style={{ fontSize: 13, display: "block", marginBottom: 4 }}>
              <input
                type="checkbox"
                name="multiple_jobs"
                style={{ width: "auto", marginRight: 8 }}
              />
              There are only two jobs in total — this one and one other, counting a spouse&apos;s
              job if you file jointly
            </label>
            <p className="lock" style={{ marginTop: 0 }}>
              Tick this only if you tick the same box on the W-4 for the other job. If the two jobs
              pay very differently, or there are more than two, the estimator at irs.gov/W4App is
              more accurate — put what it gives you into Step 4 instead.
            </p>

            <h3 style={{ marginTop: 20 }}>Step 3 · Dependents and other credits</h3>
            <p className="lock" style={{ marginTop: 0 }}>
              Only if your total income will be $200,000 or less, or $400,000 or less filing
              jointly.
            </p>
            <div className="row2">
              <label className="field">
                Qualifying children under 17
                <input
                  name="qualifying_children"
                  type="number"
                  min={0}
                  step={1}
                  value={children}
                  onChange={(e) => setChildren(Math.max(0, Number(e.target.value) || 0))}
                />
                <span className="lock">
                  {children} × {usd(W4_CREDITS.perQualifyingChild)} = {usd(childAmount)}
                </span>
              </label>
              <label className="field">
                Other dependents
                <input
                  name="other_dependents"
                  type="number"
                  min={0}
                  step={1}
                  value={dependents}
                  onChange={(e) => setDependents(Math.max(0, Number(e.target.value) || 0))}
                />
                <span className="lock">
                  {dependents} × {usd(W4_CREDITS.perOtherDependent)} = {usd(dependentAmount)}
                </span>
              </label>
              <label className="field">
                Other credits
                <input name="other_credits" type="number" min={0} step={1} defaultValue={0} />
                <span className="lock">Whole dollars</span>
              </label>
            </div>
            <p className="sub" style={{ marginTop: 0 }}>
              Step 3 total, before other credits: <strong>{usd(childAmount + dependentAmount)}</strong>
            </p>

            <h3 style={{ marginTop: 20 }}>Step 4 · Other adjustments</h3>
            <p className="lock" style={{ marginTop: 0 }}>
              All optional, and all in whole dollars for the year.
            </p>
            <div className="row2">
              <label className="field">
                (a) Other income, not from jobs
                <input name="other_income" type="number" min={0} step={1} defaultValue={0} />
                <span className="lock">Interest, dividends, retirement income</span>
              </label>
              <label className="field">
                (b) Deductions
                <input name="deductions" type="number" min={0} step={1} defaultValue={0} />
                <span className="lock">Beyond the standard deduction</span>
              </label>
              <label className="field">
                (c) Extra withholding
                <input name="extra_withholding" type="number" min={0} step={1} defaultValue={0} />
                <span className="lock">Additional tax each pay period</span>
              </label>
            </div>
          </>
        )}

        <h3 style={{ marginTop: 24 }}>Step 5 · Sign</h3>
        <div className="alert">
          Under penalties of perjury, you declare that this certificate, to the best of your
          knowledge and belief, is true, correct, and complete.
        </div>

        <label style={{ fontSize: 13, display: "block", marginBottom: 12 }}>
          <input type="checkbox" name="certify" style={{ width: "auto", marginRight: 8 }} required />
          I have read the declaration above and it is true
        </label>

        <div className="row2" style={{ alignItems: "flex-end" }}>
          <label className="field" style={{ flex: 2 }}>
            Type your full name to sign
            <input
              name="signer_name"
              required
              placeholder={`${firstName} ${lastName}`.trim()}
            />
          </label>
          <button className="btn gold" type="submit" disabled={pending}>
            {pending ? "Signing…" : "Sign and file"}
          </button>
        </div>
        <p className="lock" style={{ margin: "10px 0 0" }}>
          The employer section at the bottom of the form is filled in for you. Signing records your
          name, the date and time, and the address you signed from. The form cannot be changed
          afterwards — if something needs correcting you complete a new one, which replaces this.
        </p>
      </form>
    </div>
  );
}

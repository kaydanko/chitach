import { invoke } from "@tauri-apps/api/core";
import { hidePanels, showPanel } from "./ui.ts";

/**
 * Екран підтримки проєкту.
 *
 * Той самий, що у версіях для macOS та Android: банка monobank із
 * наперед вписаною сумою й номер картки з кнопкою копіювання. Імені
 * отримувача тут немає — воно потрібне лише для переказу за IBAN, а
 * банка й картка приймають гроші без нього.
 *
 * Адресу банки складає Rust: приймати сюди готове посилання означало б
 * дати книзі відкривати назовні будь-що.
 */

const AMOUNTS = [100, 200, 500];

const TEXT = {
  body:
    "Chytach робить одна людина у вільний час. Без реклами, без підписок і " +
    "без збору даних. Якщо застосунок став вам у пригоді, можна пригостити " +
    "розробника кавою. Внески йдуть на час для нових функцій.",
  voluntary:
    "Це повністю добровільно. Читалка лишиться такою ж і без внеску.",
  jarNote:
    "Відкриється банка monobank — у застосунку банку або в браузері. " +
    "Платити можна карткою будь-якого банку; сума в гривнях.",
  currencyNote:
    "Картка гривнева (UAH). Якщо ви платите карткою в іншій валюті, ваш " +
    "банк сконвертує суму за своїм курсом і може взяти комісію — варто " +
    "глянути, скільки спишеться.",
  copy: "Скопіювати",
  copied: "Скопійовано!",
};

const byId = <T extends HTMLElement>(id: string): T =>
  document.getElementById(id) as T;

let chosen: number | null = AMOUNTS[1];
let ready = false;

/** Номер картки групами по чотири — так його легше звірити очима. */
function grouped(value: string): string {
  return value.replace(/(.{4})/g, "$1 ").trim();
}

function highlight(): void {
  for (const button of byId("donate-amounts").children) {
    button.classList.toggle(
      "chosen",
      Number((button as HTMLElement).dataset.amount) === chosen,
    );
  }
}

async function build(inTauri: boolean): Promise<void> {
  if (ready) return;
  ready = true;

  byId("donate-body").textContent = TEXT.body;
  byId("donate-voluntary").textContent = TEXT.voluntary;
  byId("donate-jar-note").textContent = TEXT.jarNote;
  byId("donate-currency-note").textContent = TEXT.currencyNote;

  const amounts = byId("donate-amounts");
  amounts.replaceChildren();
  for (const amount of AMOUNTS) {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.amount = String(amount);
    button.textContent = `${amount} ₴`;
    button.onclick = () => {
      chosen = amount;
      byId<HTMLInputElement>("donate-custom").value = "";
      highlight();
    };
    amounts.append(button);
  }
  highlight();

  // Щойно в полі зʼявляється число, готові суми гаснуть.
  byId<HTMLInputElement>("donate-custom").oninput = (event) => {
    const typed = Number((event.target as HTMLInputElement).value);
    chosen = Number.isFinite(typed) && typed > 0 ? typed : null;
    highlight();
  };

  byId("donate-go").onclick = () => {
    if (!inTauri) return;
    invoke("open_jar", { amount: chosen }).catch(() => {});
  };

  const card = inTauri ? await invoke<string>("donation_card") : "";
  byId("donate-card").textContent = grouped(card);

  const copy = byId<HTMLButtonElement>("donate-copy");
  copy.onclick = async () => {
    try {
      await window.navigator.clipboard.writeText(card);
      copy.textContent = TEXT.copied;
      window.setTimeout(() => (copy.textContent = TEXT.copy), 2000);
    } catch {
      // Буфер обміну може бути недоступний — номер і так видно й можна
      // виділити мишею.
    }
  };

  byId("donate-close").onclick = () => hidePanels();
}

export async function openSupport(inTauri: boolean, hasOpenBook: boolean): Promise<void> {
  await build(inTauri);
  byId("donate-close").textContent = hasOpenBook
    ? "Повернутися до читання"
    : "Не зараз";
  showPanel("support");
}

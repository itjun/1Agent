// Pages 发布时生成同源清单；离线或读取失败时保留 GitHub 发布页入口。
async function loadRelease() {
  const status = document.querySelector("[data-release-status]");
  try {
    const response = await fetch("release.json", { signal: AbortSignal.timeout(6000) });
    if (!response.ok) throw new Error(`Release metadata: ${response.status}`);
    const release = await response.json();
    if (typeof release.version !== "string" || !Array.isArray(release.assets)) {
      throw new Error("Invalid release metadata");
    }
    const asset = release.assets.find(item =>
      typeof item.name === "string" && /^1Agent-.+-mac-arm64\.dmg$/.test(item.name) &&
      typeof item.url === "string" &&
      /^https:\/\/github\.com\/itjun\/1Agent\/releases\/download\/[^/?#]+\/1Agent-[^/?#]+-mac-arm64\.dmg$/.test(item.url)
    );
    if (!asset) throw new Error("No macOS package in release");
    for (const element of document.querySelectorAll("[data-version]")) {
      element.textContent = release.version;
    }
    for (const link of document.querySelectorAll("[data-download]")) link.href = asset.url;
    if (typeof asset.size === "number" && Number.isFinite(asset.size) && asset.size > 0) {
      for (const element of document.querySelectorAll("[data-download-size]")) {
        element.textContent = `${(asset.size / 1024 / 1024).toFixed(1)} MB · Apple 芯片`;
      }
    }
  } catch {
    if (status) {
      status.replaceChildren("安装包信息暂时不可用，请前往 ");
      const link = document.createElement("a");
      link.href = "https://github.com/itjun/1Agent/releases/latest";
      link.textContent = "GitHub 发布页";
      status.append(link, " 下载。");
    }
  }
}

for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    if (button.disabled) return;
    button.disabled = true;
    const status = document.querySelector("#copy-status");
    try {
      await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
      status.textContent = "命令已复制。";
      button.textContent = "已复制";
    } catch {
      status.textContent = "未能复制，请选中命令后手动复制。";
      button.textContent = "手动复制";
    } finally {
      button.disabled = false;
    }
  });
}


const slides = [...document.querySelectorAll(".gallery-slide")];
const slideButtons = [...document.querySelectorAll("[data-slide]")];
let slideIndex = 0;
function showSlide(index) {
  slideIndex = (index + slides.length) % slides.length;
  slides.forEach((slide, i) => { slide.hidden = i !== slideIndex; });
  slideButtons.forEach((button, i) => button.setAttribute("aria-pressed", String(i === slideIndex)));
}
slideButtons.forEach(button => button.addEventListener("click", () => showSlide(Number(button.dataset.slide))));
document.querySelector(".gallery-prev")?.addEventListener("click", () => showSlide(slideIndex - 1));
document.querySelector(".gallery-next")?.addEventListener("click", () => showSlide(slideIndex + 1));
document.querySelector(".showcase")?.addEventListener("keydown", event => {
  if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
  event.preventDefault();
  showSlide(slideIndex + (event.key === "ArrowLeft" ? -1 : 1));
});

const workflowTabs = [...document.querySelectorAll("[data-workflow]")];
function selectWorkflow(tab) {
  workflowTabs.forEach(button => {
    const isSelected = button === tab;
    button.setAttribute("aria-selected", String(isSelected));
    button.tabIndex = isSelected ? 0 : -1;
  });
  const image = document.querySelector("#workflow-image");
  image.src = `assets/${tab.dataset.workflow}`;
  image.alt = tab.dataset.workflowAlt;
}
workflowTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectWorkflow(tab));
  tab.addEventListener("keydown", event => {
    let next;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (index + 1) % workflowTabs.length;
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (index - 1 + workflowTabs.length) % workflowTabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = workflowTabs.length - 1;
    else return;
    event.preventDefault();
    selectWorkflow(workflowTabs[next]);
    workflowTabs[next].focus();
  });
});

const downloadOptions = document.querySelector(".download-options");
document.addEventListener("click", event => {
  if (downloadOptions && !event.target.closest(".download-split")) downloadOptions.open = false;
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && downloadOptions?.open) {
    downloadOptions.open = false;
    downloadOptions.querySelector("summary").focus();
  }
});

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  document.querySelectorAll("[data-theme-choice]").forEach(button => {
    button.setAttribute("aria-pressed", String(button.dataset.themeChoice === theme));
  });
  document.querySelector('meta[name="theme-color"]').content = theme === "dark" ? "#151515" : "#ffffff";
}
try {
  if (localStorage.getItem("oneagent-website-theme") === "dark") setTheme("dark");
} catch { /* 存储不可用时使用默认浅色外观。 */ }
document.querySelectorAll("[data-theme-choice]").forEach(button => button.addEventListener("click", () => {
  const theme = button.dataset.themeChoice;
  setTheme(theme);
  try { localStorage.setItem("oneagent-website-theme", theme); } catch { /* 外观仍在当前页面生效。 */ }
}));

loadRelease();

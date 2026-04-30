let installedApps = [];
let orphanData = {};  // {子目录名: [完整路径列表]}
let autoThemeTimer = null;
let autoThemeEnabled = localStorage.getItem('autoThemeEnabled') !== 'false';  // 默认开启

// 检测系统主题是否深色
function isSystemDark() {
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
}

// 深色时段: 22:00 - 06:00 或系统深色模式
function isDarkTime() {
  const h = new Date().getHours();
  const isNightTime = h >= 22 || h < 6;
  if (autoThemeEnabled) {
    // 夜间时段强制深色，否则跟随系统主题
    return isNightTime || isSystemDark();
  }
  // 手动模式：仅根据时段
  return isNightTime;
}

function applyTheme(dark) {
  if (dark) {
    document.documentElement.classList.add('dark');
    document.getElementById('themeToggle').textContent = '☀️';
  } else {
    document.documentElement.classList.remove('dark');
    document.getElementById('themeToggle').textContent = '🌙';
  }
}

function applyAutoTheme() {
  if (!autoThemeEnabled) return;
  applyTheme(isDarkTime());
}

function scheduleAutoTheme() {
  if (autoThemeTimer) clearInterval(autoThemeTimer);
  autoThemeTimer = setInterval(() => {
    if (autoThemeEnabled) applyTheme(isDarkTime());
  }, 30000); // 每30秒检查一次
  // 监听系统主题变化
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (autoThemeEnabled) applyTheme(isDarkTime());
    });
  }
  // 立即应用一次（无论auto是否开启，先设置正确的初始主题）
  applyTheme(isDarkTime());
  const sw = document.getElementById('autoSwitch');
  if (autoThemeEnabled) {
    sw.classList.add('on');
  } else {
    sw.classList.remove('on');
  }
}

let manualOverride = false;
function toggleTheme() {
  manualOverride = true;
  const isDark = document.documentElement.classList.contains('dark');
  applyTheme(!isDark);
  if (autoThemeTimer) clearInterval(autoThemeTimer);
  // 60秒后恢复自动
  setTimeout(() => {
    manualOverride = false;
    scheduleAutoTheme();
  }, 60000);
}

function toggleAutoTheme() {
  autoThemeEnabled = !autoThemeEnabled;
  localStorage.setItem('autoThemeEnabled', autoThemeEnabled);
  const sw = document.getElementById('autoSwitch');
  if (autoThemeEnabled) {
    sw.classList.add('on');
    applyTheme(isDarkTime());
    // 恢复定时检查
    if (autoThemeTimer) clearInterval(autoThemeTimer);
    autoThemeTimer = setInterval(() => {
      if (autoThemeEnabled) applyTheme(isDarkTime());
    }, 30000);
  } else {
    sw.classList.remove('on');
    // 关闭时不切换主题，保持当前状态
  }
}

// ========== 全局状态 ==========

// ========== 初始化 ==========
window.onload = function() {
  scheduleAutoTheme();
  doScan();
};

function toggleInstalledList(btn) {
  const list = document.getElementById("installed-list");
  const isHidden = list.style.display === "none";
  if (isHidden) {
    list.style.display = "block";
    btn.textContent = "▼ 收起";
  } else {
    list.style.display = "none";
    btn.textContent = "▶ 展开";
  }
}

async function doScan() {
  const btn = document.getElementById("scanBtn");
  const status = document.getElementById("status");
  btn.disabled = true;
  status.className = "loading";
  status.textContent = "⏳ 正在扫描...";
  // 扫描期间按钮显示 spinner
  btn.textContent = "⏳ 扫描中...";
  document.getElementById("orphan-list").innerHTML = "";
  document.getElementById("deleteBtn").disabled = true;
  document.getElementById("selectInfo").textContent = "";

  try {
    const apiBase = './';
    console.log('Fetching:', apiBase + 'api/scan');
    const res = await fetch(apiBase + 'api/scan', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({})
    });
    if (!res.ok) {
      const err = await res.text();
      console.error('API error:', res.status, err);
      status.textContent = '❌ 请求失败: ' + res.status;
      status.className = 'error';
      btn.disabled = false;
      btn.textContent = '🔍 开始扫描';
      return;
    }
    const data = await res.json();
    installedApps = data.installed || [];
    // 兼容新后端格式：数组 [{app, vol, path, dirs}] -> 对象 {子目录名: [完整路径]}
    if (Array.isArray(data.orphan)) {
      orphanData = {};
      for (const item of data.orphan) {
        const subName = item.app;
        if (!orphanData[subName]) orphanData[subName] = [];
        orphanData[subName].push(item.path);
      }
    } else {
      orphanData = data.orphan || {};
    }

    document.getElementById("installed-count").textContent = installedApps.length;
    document.getElementById("orphan-list").innerHTML = "";

    const orphanNames = Object.keys(orphanData);
    const totalOrphan = orphanNames.length;

    // 计算涉及的 vol 数量
    const volsUsed = new Set();
    for (const paths of Object.values(orphanData)) {
      for (const p of paths) {
        const m = p.match(/^\/(vol\d+)\//);
        if (m) volsUsed.add(m[1]);
      }
    }

    document.getElementById("orphan-count").textContent = totalOrphan;
    document.getElementById("vol-count").textContent = volsUsed.size;

    if (totalOrphan === 0) {
      document.getElementById("orphan-list").innerHTML =
        "<div class='empty'>🎉 没有发现残余目录，所有目录都有对应的已安装应用</div>";
    } else {
      let html = `<div class="table-wrapper"><table class="orphan-table"><thead><tr><th style="width:40px;"><input type="checkbox" id="selectAll" onchange="toggleSelectAll(this)"></th><th>子目录名</th><th>所在 vol 目录</th><th>完整路径</th></tr></thead><tbody>`;
      for (const subName of orphanNames) {
        const paths = orphanData[subName];
        const vols = [];
        const seenVols = new Set();
        for (const p of paths) {
          const m = p.match(/^\/(vol\d+)\//);
          if (m && !seenVols.has(m[1])) {
            seenVols.add(m[1]);
            vols.push(m[1]);
          }
        }
        const volStr = vols.join(", ");
        const pathsStr = paths.join("\n");
        const cbId = "cb_" + subName.replace(/[^a-zA-Z0-9]/g, "_");
        const firstPath = (paths[0] || "").replace(/"/g, "&quot;");
        html += `<tr>
          <td><input type="checkbox" class="row-cb" id="${cbId}" data-subname="${subName}" data-fullpath="${firstPath}" onchange="updateSelectInfo()"></td>
          <td style="font-family:monospace;font-size:13px;white-space:nowrap;">${subName}</td>
          <td style="font-family:monospace;font-size:13px;color:#666;">${volStr}</td>
          <td class="paths-cell" title="${pathsStr.replace(/"/g, '&quot;')}">${pathsStr}</td>
        </tr>`;
      }
      html += "</tbody></table></div>";
      document.getElementById("orphan-list").innerHTML = html;
    }

    if (installedApps.length > 0) {
      // installedApps: ["appId", "appId", ...]
      // 通过扫描结果带回的详情渲染（显示 app name 即可）
      let ihtml = "<table><thead><tr><th>显示名称</th><th>应用标识</th></tr></thead><tbody>";
      for (const app of installedApps) {
        const appname = typeof app === 'object' ? app.appname : app;
        const displayName = typeof app === 'object' ? app.display_name : app;
        ihtml += `<tr><td>${displayName}</td><td style="font-family:monospace;font-size:13px;">${appname}</td></tr>`;
      }
      ihtml += "</tbody></table>";
      document.getElementById("installed-list").innerHTML = ihtml;
    }

    status.className = "success";
    status.textContent = "✅ 扫描完成";
  } catch (e) {
    status.className = "error";
    status.textContent = "❌ 扫描失败: " + e.message;
  } finally {
    btn.disabled = false;
    btn.textContent = "🔍 开始扫描";
  }
}

function toggleSelectAll(el) {
  document.querySelectorAll(".row-cb").forEach(cb => cb.checked = el.checked);
  updateSelectInfo();
}

function updateSelectInfo() {
  const checked = document.querySelectorAll(".row-cb:checked");
  const deleteBtn = document.getElementById("deleteBtn");
  const selectInfo = document.getElementById("selectInfo");
  if (checked.length > 0) {
    deleteBtn.disabled = false;
    let totalDirs = 0;
    for (const cb of checked) {
      const subName = cb.dataset.subname;
      totalDirs += (orphanData[subName] || []).length;
    }
    selectInfo.textContent = `已选 ${checked.length} 个子目录，共 ${totalDirs} 个路径`;
  } else {
    deleteBtn.disabled = true;
    selectInfo.textContent = "";
  }
}

function confirmDelete() {
  const checked = document.querySelectorAll(".row-cb:checked");
  if (checked.length === 0) return;

  const allPaths = [];
  for (const cb of checked) {
    // 优先用 orphanData（扫描时缓存），fallback 到 data-fullpath（直接在 DOM 上）
    const subName = cb.dataset.subname;
    if (orphanData[subName] && orphanData[subName].length > 0) {
      allPaths.push(...orphanData[subName]);
    } else if (cb.dataset.fullpath) {
      allPaths.push(cb.dataset.fullpath);
    }
  }

  document.getElementById("confirmCount").textContent = checked.length;
  document.getElementById("confirmPathsCount").textContent = allPaths.length;
  document.getElementById("confirmPaths").innerHTML = allPaths.map(p => `<div>${p}</div>`).join("");
  document.getElementById("confirmModal").style.display = "flex";
}

function closeModal() {
  document.getElementById("confirmModal").style.display = "none";
  document.getElementById("deleteUsersCheckbox").checked = false;
}

async function doDelete() {
  const checked = document.querySelectorAll(".row-cb:checked");
  if (checked.length === 0) return;

  const allPaths = [];
  for (const cb of checked) {
    const subName = cb.dataset.subname;
    if (orphanData[subName] && orphanData[subName].length > 0) {
      allPaths.push(...orphanData[subName]);
    } else if (cb.dataset.fullpath) {
      allPaths.push(cb.dataset.fullpath);
    }
  }

  // 在关闭弹窗前先读取复选框值
  const checkbox = document.getElementById("deleteUsersCheckbox");
  const deleteUsers = checkbox ? checkbox.checked : false;
  console.log("checkbox element:", checkbox, "checked:", deleteUsers);
  console.log("allPaths to delete:", allPaths);

  closeModal();
  const status = document.getElementById("status");
  status.className = "loading";
  status.textContent = "⏳ 正在删除...";

  try {
    const deleteUrl = './api/delete';
    console.log('Fetching delete:', deleteUrl);
    const res = await fetch(deleteUrl, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({paths: allPaths, delete_users: deleteUsers})
    });
    const result = await res.json();

    const total = result.total || 0;
    const failures = result.failures || 0;
    const usersDeleted = result.users_deleted || [];
    const usersFailed = result.users_failed || [];

    // 构建结果消息
    let msg = `📁 已删除目录: ${total} 个`;
    if (failures > 0) msg += `，失败 ${failures} 个`;
    if (usersDeleted.length > 0) msg += `\n👤 已删除用户: ${usersDeleted.length} 个 (${usersDeleted.join(', ')})`;
    if (usersFailed.length > 0) msg += `\n❌ 用户删除失败: ${usersFailed.length} 个 (${usersFailed.join(', ')})`;

    status.className = (failures > 0 || usersFailed.length > 0) ? "warning" : "success";
    status.textContent = msg;
    alert(msg);

    // 重新扫描
    setTimeout(() => doScan(), 1000);
  } catch (e) {
    status.className = "error";
    status.textContent = "❌ 删除失败: " + e.message;
  }
}

// 赞助弹窗
function showSponsorModal() {
  document.getElementById('sponsorModal').style.display = 'block';
}
function showSponsorImgFull(img) {
  document.getElementById('sponsorImgFull').src = img.src;
  document.getElementById('sponsorImgOverlay').style.display = 'flex';
}
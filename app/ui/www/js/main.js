/**
 * FnClearup CGI - JavaScript
 * 使用命名空间封装全局变量
 */
(function() {
  'use strict';

  // ========== 命名空间 ==========
  const App = {
    installedApps: [],
    orphanData: {},  // {子目录名: [完整路径列表]}
    autoThemeTimer: null,
    autoThemeEnabled: localStorage.getItem('autoThemeEnabled') !== 'false',  // 默认开启
    mountsLoaded: false,  // 网盘挂载数据是否已加载
    vol02Scanned: false,   // vol02 是否已扫描
    manualOverride: false
  };

  // ========== API 工具 ==========
  const API = {
    base: './',
    async post(path, body) {
      const res = await fetch(this.base + path, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(body)
      });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}: ${await res.text()}`);
      }
      return res.json();
    }
  };

  // ========== DOM 工具 ==========
  const $ = (id) => document.getElementById(id);

  // ========== 主题管理 ==========
  function isSystemDark() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  // 深色时段: 22:00 - 06:00 或系统深色模式
  function isDarkTime() {
    const h = new Date().getHours();
    const isNightTime = h >= 22 || h < 6;
    if (App.autoThemeEnabled) {
      return isNightTime || isSystemDark();
    }
    return isNightTime;
  }

  function applyTheme(dark) {
    const html = document.documentElement;
    const themeBtn = $('themeToggle');
    if (dark) {
      html.classList.add('dark');
      themeBtn.textContent = '☀️';
    } else {
      html.classList.remove('dark');
      themeBtn.textContent = '🌙';
    }
  }

  function applyAutoTheme() {
    if (!App.autoThemeEnabled) return;
    applyTheme(isDarkTime());
  }

  function scheduleAutoTheme() {
    if (App.autoThemeTimer) clearInterval(App.autoThemeTimer);
    App.autoThemeTimer = setInterval(() => {
      if (App.autoThemeEnabled) applyTheme(isDarkTime());
    }, 30000); // 每30秒检查一次
    // 监听系统主题变化
    if (window.matchMedia) {
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        if (App.autoThemeEnabled) applyTheme(isDarkTime());
      });
    }
    // 立即应用一次
    applyTheme(isDarkTime());
    const sw = $('autoSwitch');
    if (App.autoThemeEnabled) {
      sw.classList.add('on');
    } else {
      sw.classList.remove('on');
    }
  }

  function toggleTheme() {
    App.manualOverride = true;
    const isDark = document.documentElement.classList.contains('dark');
    applyTheme(!isDark);
    if (App.autoThemeTimer) clearInterval(App.autoThemeTimer);
    // 60秒后恢复自动
    setTimeout(() => {
      App.manualOverride = false;
      scheduleAutoTheme();
    }, 60000);
  }

  function toggleAutoTheme() {
    App.autoThemeEnabled = !App.autoThemeEnabled;
    localStorage.setItem('autoThemeEnabled', App.autoThemeEnabled);
    const sw = $('autoSwitch');
    if (App.autoThemeEnabled) {
      sw.classList.add('on');
      applyTheme(isDarkTime());
      if (App.autoThemeTimer) clearInterval(App.autoThemeTimer);
      App.autoThemeTimer = setInterval(() => {
        if (App.autoThemeEnabled) applyTheme(isDarkTime());
      }, 30000);
    } else {
      sw.classList.remove('on');
    }
  }

  // ========== 初始化 ==========
  window.onload = function() {
    scheduleAutoTheme();
    doScan();
  };

  function toggleInstalledList(btn) {
    const list = $("installed-list");
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
    const btn = $("scanBtn");
    const status = $("status");
    btn.disabled = true;
    status.className = "loading";
    status.textContent = "⏳ 正在扫描...";
    btn.textContent = "⏳ 扫描中...";
    $("orphan-list").innerHTML = "";
    $("deleteBtn").disabled = true;
    $("selectInfo").textContent = "";

    try {
      const data = await API.post('api/scan', {});
      App.installedApps = data.installed || [];

      // 兼容新后端格式：数组 [{app, vol, path, dirs}] -> 对象 {子目录名: [完整路径]}
      if (Array.isArray(data.orphan)) {
        App.orphanData = {};
        for (const item of data.orphan) {
          const subName = item.app;
          if (!App.orphanData[subName]) App.orphanData[subName] = [];
          App.orphanData[subName].push(item.path);
        }
      } else {
        App.orphanData = data.orphan || {};
      }

      $("installed-count").textContent = App.installedApps.length;

      const orphanNames = Object.keys(App.orphanData);
      const totalOrphan = orphanNames.length;

      // 计算涉及的 vol 数量
      const volsUsed = new Set();
      for (const paths of Object.values(App.orphanData)) {
        for (const p of paths) {
          const m = p.match(/^\/(vol\d+)\//);
          if (m) volsUsed.add(m[1]);
        }
      }

      $("orphan-count").textContent = totalOrphan;
      $("vol-count").textContent = volsUsed.size;

      if (totalOrphan === 0) {
        $("orphan-list").innerHTML =
          "<div class='empty'>🎉 没有发现残余目录，所有目录都有对应的已安装应用</div>";
      } else {
        let html = `<div class="table-wrapper"><table class="orphan-table"><thead><tr><th style="width:40px;"><input type="checkbox" id="selectAll" onchange="toggleSelectAll(this)"></th><th>子目录名</th><th>所在 vol 目录</th><th>完整路径</th></tr></thead><tbody>`;
        for (const subName of orphanNames) {
          const paths = App.orphanData[subName];
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
            <td style="font-family:monospace;font-size:13px;color:var(--color-text-secondary);">${volStr}</td>
            <td class="paths-cell" title="${pathsStr.replace(/"/g, '&quot;')}">${pathsStr}</td>
          </tr>`;
        }
        html += "</tbody></table></div>";
        $("orphan-list").innerHTML = html;
      }

      if (App.installedApps.length > 0) {
        let ihtml = "<table><thead><tr><th>显示名称</th><th>应用标识</th></tr></thead><tbody>";
        for (const app of App.installedApps) {
          const appname = typeof app === 'object' ? app.appname : app;
          const displayName = typeof app === 'object' ? app.display_name : app;
          // HTML 转义防止 XSS
          const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
          ihtml += `<tr><td>${esc(displayName)}</td><td style="font-family:monospace;font-size:13px;">${esc(appname)}</td></tr>`;
        }
        ihtml += "</tbody></table>";
        $("installed-list").innerHTML = ihtml;
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
    const deleteBtn = $("deleteBtn");
    const selectInfo = $("selectInfo");
    if (checked.length > 0) {
      deleteBtn.disabled = false;
      let totalDirs = 0;
      for (const cb of checked) {
        const subName = cb.dataset.subname;
        totalDirs += (App.orphanData[subName] || []).length;
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
      const subName = cb.dataset.subname;
      if (App.orphanData[subName] && App.orphanData[subName].length > 0) {
        allPaths.push(...App.orphanData[subName]);
      } else if (cb.dataset.fullpath) {
        allPaths.push(cb.dataset.fullpath);
      }
    }

    $("confirmCount").textContent = checked.length;
    $("confirmPathsCount").textContent = allPaths.length;
    // HTML 转义防止 XSS
    const escPath = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    $("confirmPaths").innerHTML = allPaths.map(p => `<div>${escPath(p)}</div>`).join("");
    $("confirmModal").style.display = "flex";
  }

  function closeModal() {
    $("confirmModal").style.display = "none";
    $("deleteUsersCheckbox").checked = false;
  }

  async function doDelete() {
    const checked = document.querySelectorAll(".row-cb:checked");
    if (checked.length === 0) return;

    const allPaths = [];
    for (const cb of checked) {
      const subName = cb.dataset.subname;
      if (App.orphanData[subName] && App.orphanData[subName].length > 0) {
        allPaths.push(...App.orphanData[subName]);
      } else if (cb.dataset.fullpath) {
        allPaths.push(cb.dataset.fullpath);
      }
    }

    const checkbox = $("deleteUsersCheckbox");
    const deleteUsers = checkbox ? checkbox.checked : false;

    closeModal();
    const status = $("status");
    status.className = "loading";
    status.textContent = "⏳ 正在删除...";

    try {
      const result = await API.post('api/delete', {paths: allPaths, delete_users: deleteUsers});

      const total = result.total || 0;
      const failures = result.failures || 0;
      const usersDeleted = result.users_deleted || [];
      const usersFailed = result.users_failed || [];

      let msg = `📁 已删除目录: ${total} 个`;
      if (failures > 0) msg += `，失败 ${failures} 个`;
      if (usersDeleted.length > 0) msg += `\n👤 已删除用户: ${usersDeleted.length} 个 (${usersDeleted.join(', ')})`;
      if (usersFailed.length > 0) msg += `\n❌ 用户删除失败: ${usersFailed.length} 个 (${usersFailed.join(', ')})`;

      status.className = (failures > 0 || usersFailed.length > 0) ? "warning" : "success";
      status.textContent = msg;
      alert(msg);

      setTimeout(() => doScan(), 1000);
    } catch (e) {
      status.className = "error";
      status.textContent = "❌ 删除失败: " + e.message;
    }
  }

  // 赞助弹窗
  function showSponsorModal() {
    $('sponsorModal').style.display = 'block';
  }
  function showSponsorImgFull(img) {
    $('sponsorImgFull').src = img.src;
    $('sponsorImgOverlay').style.display = 'flex';
  }


  // ========== Tab 切换 ==========
  function switchTab(tabName) {
    // 更新按钮状态
    document.querySelectorAll('.tab-btn').forEach(btn => {
      if (btn.dataset.tab === tabName) {
        btn.classList.add('active');
        btn.setAttribute('aria-selected', 'true');
      } else {
        btn.classList.remove('active');
        btn.setAttribute('aria-selected', 'false');
      }
    });
    // 更新面板显示
    document.querySelectorAll('.tab-panel').forEach(panel => {
      if (panel.dataset.panel === tabName) {
        panel.classList.add('active');
      } else {
        panel.classList.remove('active');
      }
    });
    // 切换到网盘挂载 Tab 时自动加载数据
    if (tabName === 'disk') {
      if (!App.mountsLoaded) { App.mountsLoaded = true; loadMounts(); }
      if (!App.vol02Scanned) { scanVol02(); }
    }
  }



  // ========== /vol02 未挂载目录 ==========
  async function scanVol02() {
    App.vol02Scanned = true;
    await loadVol02();
    // 扫描完成后自动展开列表
    const btn = $("toggleVol02Btn");
    const list = $("vol02-list");
    if (btn && list && list.style.display === "none") {
      list.style.display = "block";
      btn.textContent = "▼ 收起";
    }
  }

  async function loadVol02() {
    console.log('[loadVol02] called');
    const status = $('vol02-status');
    const list = $('vol02-list');
    console.log('[loadVol02] status element:', status);
    console.log('[loadVol02] list element:', list);
    status.className = 'loading';
    status.textContent = '⏳ 正在加载...';
    list.innerHTML = '';

    try {
      const data = await API.post('api/vol02', {});
      console.log('[loadVol02] received data:', JSON.stringify(data));
      const vol02_dirs = data.vol02_dirs || [];
      const mounted_points = data.mounted_points || [];
      console.log('[loadVol02] vol02_dirs:', vol02_dirs);
      console.log('[loadVol02] mounted_points:', mounted_points);

      // Build a set of mounted point directory names (last path component)
      const mountedSet = new Set();
      for (const mp of mounted_points) {
        // mp like /mnt/cloud/baidu or /mnt/media
        const name = mp.split('/').pop();
        console.log('[loadVol02] mp:', mp, '-> name:', name);
        if (name) mountedSet.add(name);
      }
      console.log('[loadVol02] mountedSet:', [...mountedSet]);

      // Filter vol02 dirs that are NOT in mountedSet
      const unmounted = vol02_dirs.filter(d => !mountedSet.has(d));
      console.log('[loadVol02] unmounted:', unmounted);

      status.className = 'success';
      status.textContent = `✅ /vol02 共 ${vol02_dirs.length} 个子目录，其中 ${unmounted.length} 个未在网盘挂载中使用`;

      if (unmounted.length === 0) {
        list.innerHTML = '<div class=\'empty\'>🎉 所有 /vol02 子目录都已在网盘挂载中使用</div>';
        return;
      }

      // Use event delegation - attach listener to list container
      let html = `<div class="table-wrapper"><table class="orphan-table" id="vol02-table"><thead><tr><th style="width:40px;"><input type="checkbox" id="selectAllVol02"></th><th>目录名</th><th>完整路径</th></tr></thead><tbody>`;
      for (const dirName of unmounted) {
        const fullPath = '/vol02/' + dirName;
        const cbId = 'vol02_cb_' + dirName.replace(/[^a-zA-Z0-9]/g, '_');
        const escPath = fullPath.replace(/&/g,'&amp;').replace(/"/g,'&quot;');
        html += `<tr>
          <td><input type="checkbox" class="vol02-row-cb" id="${cbId}" data-dirname="${dirName}" data-fullpath="${escPath}"></td>
          <td style="font-family:monospace;font-size:13px;white-space:nowrap;">${dirName}</td>
          <td style="font-family:monospace;font-size:13px;color:var(--color-text-secondary);" title="${escPath}">${fullPath}</td>
        </tr>`;
      }
      html += '</tbody></table></div>';
      list.innerHTML = html;
      
      // Event delegation for vol02 table
      const vol02Table = document.getElementById('vol02-table');
      if (vol02Table) {
        vol02Table.addEventListener('change', function(e) {
          if (e.target && e.target.classList.contains('vol02-row-cb')) {
            updateSelectInfoVol02();
          }
          if (e.target && e.target.id === 'selectAllVol02') {
            document.querySelectorAll('.vol02-row-cb').forEach(cb => cb.checked = e.target.checked);
            updateSelectInfoVol02();
          }
        });
      }
    } catch (e) {
      console.error('[loadVol02] error:', e);
      status.className = 'error';
      status.textContent = '❌ 加载失败: ' + e.message;
    }
  }

  function toggleSelectAllVol02(el) {
    document.querySelectorAll('.vol02-row-cb').forEach(cb => cb.checked = el.checked);
    updateSelectInfoVol02();
  }

  function updateSelectInfoVol02() {
    const checked = document.querySelectorAll('.vol02-row-cb:checked');
    const info = $('vol02-select-info');
    const deleteBtn = $('deleteVol02Btn');
    if (info) {
      info.textContent = checked.length > 0 ? `已选 ${checked.length} 个目录` : '';
    }
    if (deleteBtn) {
      deleteBtn.disabled = checked.length === 0;
    }
  }

  function getSelectedVol02Paths() {
    const checked = document.querySelectorAll('.vol02-row-cb:checked');
    const paths = [];
    for (const cb of checked) {
      paths.push(cb.dataset.fullpath);
    }
    return paths;
  }

  function confirmDeleteVol02() {
    const paths = getSelectedVol02Paths();
    if (paths.length === 0) return;
    const msg = `即将删除以下 ${paths.length} 个目录：\n${paths.join('\n')}\n\n⚠️ 此操作不可恢复！`;
    if (!confirm(msg)) return;
    doDeleteVol02(paths);
  }

  async function doDeleteVol02(paths) {
    console.log('[doDeleteVol02] ENTERED with paths:', JSON.stringify(paths));
    const status = $('vol02-status');
    status.className = 'loading';
    status.textContent = '⏳ 正在删除...';

    try {
      console.log('[doDeleteVol02] calling API.post with body:', JSON.stringify({ paths: paths, delete_users: false }));
      const result = await API.post('api/delete', { paths: paths, delete_users: false });
      console.log('[doDeleteVol02] result:', result);
      const total = result.total || 0;
      const failures = result.failures || 0;
      let msg = `📁 已删除: ${total} 个`;
      if (failures > 0) msg += `，失败 ${failures} 个`;
      status.className = failures > 0 ? 'warning' : 'success';
      status.textContent = msg;
      alert(msg);
      // Auto-rescan both mounts and vol02
      App.mountsLoaded = false;
      App.vol02Scanned = false;
      loadMounts();
      App.mountsLoaded = true;
      scanVol02();
    } catch (e) {
      status.className = 'error';
      status.textContent = '❌ 删除失败: ' + e.message;
    }
  }

  // ========== 列表展开/收起 ==========
  function toggleMountsList(btn) {
    const list = $('mounts-list');
    if (!list) return;
    const isHidden = false;
    list.style.display = isHidden ? 'block' : 'none';
    btn.textContent = isHidden ? '▼ 收起' : '▶ 展开';
  }

  function toggleVol02List(btn) {
    const list = $('vol02-list');
    if (!list) return;
    const isHidden = false;
    list.style.display = isHidden ? 'block' : 'none';
    btn.textContent = isHidden ? '▼ 收起' : '▶ 展开';
  }

  // ========== 网盘挂载 ==========
  async function loadMounts() {
    const status = $('mounts-status');
    const list = $('mounts-list');
    status.className = 'loading';
    status.textContent = '⏳ 正在加载...';
    list.innerHTML = '';

    try {
      const data = await API.post('api/mounts', {});
      const mounts = data.mounts || [];

      status.className = 'success';
      status.textContent = `✅ 共 ${mounts.length} 个网盘挂载`;

      if (mounts.length === 0) {
        list.innerHTML = '<div class=\'empty\'>暂无可用的网盘挂载</div>';
        return;
      }

      let html = `<div class="table-wrapper"><table class="orphan-table"><thead><tr><th>网盘类型</th><th>挂载点</th><th>地址</th><th>路径</th><th>备注</th></tr></thead><tbody>`;
      for (const m of mounts) {
        const esc = s => String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        const proto = esc(m.proto);
        const address = esc(m.address);
        const port = esc(m.port);
        const path = esc(m.path);
        const url = `${proto}://${address}:${port}${path}`;
        const cstStr = esc(m.cloudStorageTypeStr);
        const mountpoint = esc(m.mountPoint);
        const comment = esc(m.comment);
        html += `<tr>
          <td><span class="badge badge-blue">${cstStr}</span></td>
          <td style="font-family:monospace;font-size:13px;">${mountpoint}</td>
          <td style="font-family:monospace;font-size:13px;color:var(--color-text-secondary);" title="${url}">${address}:${port}</td>
          <td style="font-family:monospace;font-size:13px;">${path}</td>
          <td style="font-size:13px;color:var(--color-text-secondary);">${comment}</td>
        </tr>`;
      }
      html += '</tbody></table></div>';
      list.innerHTML = html;
      // 加载完成后自动展开列表
      const btn = $("toggleMountsBtn");
      if (btn && list.style.display === "none") {
        list.style.display = "block";
        btn.textContent = "▼ 收起";
      }
    } catch (e) {
      status.className = 'error';
      status.textContent = '❌ 加载失败: ' + e.message;
    }
  }

  // ========== 导出全局函数 ==========
  window.toggleTheme = toggleTheme;
  window.toggleAutoTheme = toggleAutoTheme;
  window.toggleInstalledList = toggleInstalledList;
  window.toggleMountsList = toggleMountsList;
  window.toggleVol02List = toggleVol02List;
  window.doScan = doScan;
  window.toggleSelectAll = toggleSelectAll;
  window.updateSelectInfo = updateSelectInfo;
  window.confirmDelete = confirmDelete;
  window.closeModal = closeModal;
  window.doDelete = doDelete;
  window.showSponsorModal = showSponsorModal;
  window.showSponsorImgFull = showSponsorImgFull;
  window.switchTab = switchTab;
  window.loadMounts = loadMounts;
  window.loadVol02 = loadVol02;
  window.scanVol02 = scanVol02;
  window.confirmDeleteVol02 = confirmDeleteVol02;
  window.toggleSelectAllVol02 = toggleSelectAllVol02;

})();

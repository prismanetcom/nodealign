--==============================================================
-- NodeAlign.lua  —  Auto-layout "a ritroso" per Fusion comps
-- Works in DaVinci Resolve (Fusion page) and Fusion Studio
--
-- Strategia (sink-anchored reverse layout, per componenti):
--   1. il grafo si scompone in componenti connesse (rami indipendenti)
--   2. per ogni componente: trova i sink (nodi senza output downstream);
--      i sink mantengono la loro Y; la X dei sink ancora la componente
--   3. identifica una dorsale immagine dominante fino ai sink, anche
--      attraverso Foreground; la dorsale resta orizzontale e non si ripiega
--   4. layout a ritroso: dorsale prima, poi rami laterali; si ripiegano
--      solo catene accessorie lineari, mai Merge/giunzioni o dorsali
--   5. le componenti vengono disposte FIANCO A FIANCO (niente
--      sovrapposizioni tra rami indipendenti), ordinate per Y media dei sink
--==============================================================

--========= costanti regolabili (unità griglia) =========
-- Passo e ingombro DEVONO essere indipendenti. Il vecchio NODE_W=3
-- era incompatibile col passo empirico 1.1: produceva una scala verticale.
-- Ingombro operativo coerente con quel passo; da confermare nel flow reale.
local NODE_W   = 1.0   -- soglia orizzontale per collisioni (unità SetPos)
local NODE_H   = 1.0
local PITCH_X  = 1.1   -- passo orizzontale empirico già scelto con l'utente
local ROW_GAP  = 0.75
local COMP_GAP = 3.0   -- spazio orizzontale tra rami indipendenti (unità)
local FOLD_MAX = 4     -- limite totale per una catena accessoria, non per Merge

local PITCH_Y = NODE_H + ROW_GAP -- 1.75

--========= dati =========
-- in Resolve il frame giusto è un ChildFrame dentro GetFrameList()
local function getFlow(comp)
  for _, f in ipairs(comp:GetFrameList() or {}) do
    local ok, fv = pcall(function() return f.FlowView end)
    if ok and fv then return fv end
  end
  local ok, fv = pcall(function() return comp.CurrentFrame.FlowView end)
  if ok and fv then return fv end
  error("[NodeAlign] FlowView non trovata: sei sulla pagina Fusion?")
end

local validTypes = {
  ["Image"] = true,
  ["DataType2D"] = true,
  ["Mask"] = true,
  ["DataType3D"] = true,
  ["ParticleStyle"] = true,
}

local function collectTools(comp, onlySelected)
  local list = {}
  for _, t in pairs(comp:GetToolList(onlySelected) or {}) do
    list[#list + 1] = t
  end
  return list
end

-- Macro/Group sono nodi ATOMICI. GetConnectedOutput():GetTool() può
-- restituire il tool interno che produce l'output pubblicato del gruppo.
local function topLevelTool(t)
  local seen = {}
  while t and not seen[t] do
    seen[t] = true
    local ok, parent = pcall(function() return t.ParentTool end)
    if not ok or not parent then return t end
    t = parent
  end
  return nil
end

--========= DAG: chiavi = oggetti tool (niente attributi fragili) =========
local function buildGraph(comp, tools)
  local edges, redges, inName, imageInputs, maskEdge = {}, {}, {}, {}, {}
  for _, t in ipairs(tools) do
    edges[t] = {}
    redges[t] = {}
    inName[t] = {}
    imageInputs[t] = 0
    maskEdge[t] = {}
  end
  local seen = {}
  for _, t in ipairs(tools) do
    for _, inp in pairs(t:GetInputList() or {}) do
      local okA, attrs = pcall(function() return inp:GetAttrs() end)
      local dt = okA and attrs and attrs.INPS_DataType or nil
      if okA and attrs and validTypes[dt] then
        local oOk, out = pcall(function() return inp:GetConnectedOutput() end)
        if oOk and out then
          local sOk, src = pcall(function() return out:GetTool() end)
          if sOk and src then src = topLevelTool(src) end
          if sOk and src and src ~= t and edges[src] then
            local name = attrs.INPS_ID or ""
            local lower = string.lower(name)
            local isMask = dt == "Mask" or lower:find("mask") ~= nil
            if not isMask then imageInputs[t] = imageInputs[t] + 1 end
            seen[src] = seen[src] or {}
            if not seen[src][t] then
              seen[src][t] = true
              table.insert(edges[src], t)   -- src → t (downstream)
              table.insert(redges[t], src)  -- t ← src (upstream)
              inName[src][t] = name
              maskEdge[src][t] = isMask
            else
              -- Una sorgente su immagine E mask resta una connessione immagine.
              -- Background prevale su Foreground, a parità di sorgente.
              local old = string.lower(inName[src][t])
              if not isMask and (maskEdge[src][t]
                or (not lower:find("foreground") and old:find("foreground"))) then
                inName[src][t] = name
                maskEdge[src][t] = false
              end
            end
          end
        end
      end
    end
  end
  return edges, redges, inName, imageInputs, maskEdge
end

-- input secondario = Foreground o qualunque Mask (EffectMask, ForegroundMask...)
local function isSecondaryInput(name)
  local n = string.lower(name or "")
  return n:find("foreground") ~= nil or n:find("mask") ~= nil
end

--========= componenti connesse =========
local function connectedComponents(tools, edges, redges)
  local comps, cid = {}, {}
  for _, t in ipairs(tools) do
    if not cid[t] then
      local c = { t }
      cid[t] = #comps + 1
      local stack = { t }
      while #stack > 0 do
        local u = table.remove(stack)
        for _, v in ipairs(edges[u]) do
          if not cid[v] then cid[v] = #comps + 1; c[#c + 1] = v; stack[#stack + 1] = v end
        end
        for _, v in ipairs(redges[u]) do
          if not cid[v] then cid[v] = #comps + 1; c[#c + 1] = v; stack[#stack + 1] = v end
        end
      end
      comps[#comps + 1] = c
    end
  end
  return comps, cid
end

-- Risolve le collisioni SOLO contro nodi già fissati: non sposta i consumer.
local function freeY(x, y, placed)
  while true do
    local nextY = y
    for _, p in ipairs(placed) do
      if math.abs(x - p.X) < NODE_W - 1e-6
        and math.abs(y - p.Y) < PITCH_Y - 1e-6 then
        nextY = math.max(nextY, p.Y + PITCH_Y)
      end
    end
    if nextY == y then return y end
    y = nextY
  end
end

--========= layout di una componente (a ritroso dai suoi sink) =========
-- X relative: sink = 0, upstream NEGATIVE. Ritorna anche la X dell'ancora.
local function layoutComponent(sub, edges, redges, inName, imageInputs, maskEdge, flow)
  local original, ordered = {}, {}
  for _, t in ipairs(sub) do
    local x, y = flow:GetPos(t)
    original[t] = { X = x or 0, Y = y or 0 }
    ordered[#ordered + 1] = t
  end
  local function originalLess(a, b)
    local A, B = original[a], original[b]
    if A.Y ~= B.Y then return A.Y < B.Y end
    if A.X ~= B.X then return A.X < B.X end
    return tostring(a.Name or a) < tostring(b.Name or b)
  end
  table.sort(ordered, originalLess)

  -- Ordine topologico inverso: tutti i consumer prima del produttore,
  -- ANCHE quando il ripiego li mette nella stessa colonna.
  -- Kahn evita ricorsione profonda e rileva cicli senza loop infiniti.
  local pending, queue, reverseOrder = {}, {}, {}
  local anchorX = -math.huge
  for _, t in ipairs(ordered) do
    pending[t] = #edges[t]
    if pending[t] == 0 then
      queue[#queue + 1] = t
      anchorX = math.max(anchorX, original[t].X)
    end
  end
  local head = 1
  while head <= #queue do
    local t = queue[head]
    head = head + 1
    reverseOrder[#reverseOrder + 1] = t
    local upstream = {}
    for _, s in ipairs(redges[t]) do upstream[#upstream + 1] = s end
    table.sort(upstream, originalLess)
    for _, s in ipairs(upstream) do
      pending[s] = pending[s] - 1
      if pending[s] == 0 then queue[#queue + 1] = s end
    end
  end
  if #reverseOrder ~= #sub then
    error("[NodeAlign] ciclo nel grafo: layout annullato, nessun nodo spostato")
  end

  local function junction(t)
    return string.find(string.lower(t.ID or ""), "merge") ~= nil
      or imageInputs[t] >= 2
  end
  local function inputPriority(s, t)
    local name = string.lower(inName[s][t] or "")
    if name:find("background") or name:find("sceneinput") then return 2 end
    return isSecondaryInput(name) and 0 or 1
  end

  -- Selezione della continuazione immagine dominante: percorso upstream
  -- più lungo, esclusi gli input mask. Background è solo un tie-break:
  -- un Background piatto non deve prevalere su un'intera comp in Foreground.
  -- Questo calcolo sceglie la dorsale; il PIAZZAMENTO resta dai sink a ritroso.
  local length, preferred = {}, {}
  for i = #reverseOrder, 1, -1 do
    local t = reverseOrder[i]
    length[t] = 1
    local best, bestLength, bestPriority = nil, -1, -1
    for _, s in ipairs(redges[t]) do
      if not maskEdge[s][t] then
        local priority = inputPriority(s, t)
        if length[s] > bestLength
          or (length[s] == bestLength and priority > bestPriority)
          or (length[s] == bestLength and priority == bestPriority
            and tostring(s.Name or s) < tostring(best.Name or best)) then
          best, bestLength, bestPriority = s, length[s], priority
        end
      end
    end
    preferred[t] = best
    if best then length[t] = length[best] + 1 end
  end
  local spine = {}
  for _, t in ipairs(reverseOrder) do
    if #edges[t] == 0 then
      local s = t
      while s and not spine[s] do spine[s] = true; s = preferred[s] end
    end
  end

  local col, fold, fdep, rank = {}, {}, {}, {}
  local minCol = 0
  for i, t in ipairs(reverseOrder) do
    rank[t] = i
    col[t], fold[t], fdep[t] = 0, false, 0
    -- Mai ripiegare dorsali, giunzioni o nodi condivisi. La profondità
    -- aumenta per tutta la pila e non si azzera al Merge successivo.
    if not spine[t] and not junction(t) and #redges[t] <= 1 and #edges[t] == 1 then
      local d = edges[t][1]
      local depth
      if fold[d] then
        depth = fdep[d] + 1
      elseif junction(d) and preferred[d] ~= t then
        depth = 1
      end
      if depth and depth <= FOLD_MAX then fold[t], fdep[t] = true, depth end
    end
    for _, d in ipairs(edges[t]) do
      col[t] = math.min(col[t], col[d] - (fold[t] and 0 or 1))
    end
    minCol = math.min(minCol, col[t])
  end

  local function placementPriority(t)
    if spine[t] then return 0 end
    if not fold[t] then return 1 end
    local root = t
    while fold[edges[root][1]] do root = edges[root][1] end
    -- Prima le pile dei rami laterali: restano vicine ai propri Merge.
    -- Poi gli accessori della dorsale, senza attraversare quelle pile.
    return spine[edges[root][1]] and 3 or 2
  end
  table.sort(ordered, function(a, b)
    if col[a] ~= col[b] then return col[a] > col[b] end
    local pa, pb = placementPriority(a), placementPriority(b)
    if pa ~= pb then return pa < pb end
    return rank[a] < rank[b]
  end)
  local pos, placed = {}, {}
  local function place(t, y)
    local x = col[t] * PITCH_X
    y = freeY(x, y, placed)
    pos[t] = { X = x, Y = y }
    placed[#placed + 1] = pos[t]
  end

  -- Riserva PRIMA l'intera dorsale. Nessun ramo laterale può deformarla,
  -- neppure se occupa una colonna più a destra di una sua parte upstream.
  for _, t in ipairs(ordered) do
    if spine[t] then
      local sum, n = 0, 0
      for _, d in ipairs(edges[t]) do
        if spine[d] and preferred[d] == t then
          sum = sum + pos[d].Y; n = n + 1
        end
      end
      place(t, n > 0 and sum / n or original[t].Y)
    end
  end
  -- Rami accessori: una propria riga orizzontale, oppure una pila locale.
  for _, t in ipairs(ordered) do
    if not spine[t] and not pos[t] then
      local sum = 0
      for _, d in ipairs(edges[t]) do sum = sum + pos[d].Y end
      local y = sum / #edges[t]
      if fold[t] then
        y = y + PITCH_Y
      elseif #edges[t] == 1 then
        local d = edges[t][1]
        if preferred[d] ~= t and not fold[d] then y = y + PITCH_Y end
      end
      if fold[t] then
        -- Riserva tutta la pila prima di piazzare altri rami nella colonna.
        -- I singoli freeY permettevano a mask e foto di alternarsi.
        local chain, s = {}, t
        while s and fold[s] and not pos[s] do
          chain[#chain + 1] = s
          local upstream = redges[s][1]
          s = upstream and fold[upstream] and upstream or nil
        end
        local x = col[t] * PITCH_X
        while true do
          local start = y
          for i = 1, #chain do
            local target = y + (i - 1) * PITCH_Y
            local available = freeY(x, target, placed)
            start = math.max(start, available - (i - 1) * PITCH_Y)
          end
          if start == y then break end
          y = start
        end
        for i, node in ipairs(chain) do place(node, y + (i - 1) * PITCH_Y) end
      else
        place(t, y)
      end
    end
  end
  return pos, -minCol * PITCH_X, anchorX
end

--========= modalità principale =========
local function layoutTools(comp, tools, label)
  local flow = getFlow(comp)

  -- in Resolve GetToolList include anche i modifier (spline, XYPath...):
  -- non esistono nel flow, quindi filtriamo via posizione
  local ftools = {}
  for _, t in ipairs(tools) do
    if topLevelTool(t) == t and flow:GetPos(t) ~= nil then table.insert(ftools, t) end
  end
  tools = ftools
  print(string.format("[NodeAlign] %s: nodi nel flow: %d", label, #tools))
  if #tools == 0 then return end

  local edges, redges, inName, imageInputs, maskEdge = buildGraph(comp, tools)
  local nEdges = 0
  for _, v in pairs(edges) do nEdges = nEdges + #v end
  print(string.format("[NodeAlign] connessioni: %d", nEdges))

  -- componenti connesse: ogni ramo indipendente si dispone da solo,
  -- poi le componenti vengono messe fianco a fianco (niente collisioni)
  local comps = connectedComponents(tools, edges, redges)
  print(string.format("[NodeAlign] rami indipendenti: %d", #comps))

  -- Ordina usando le ancore (Y media dei sink), non tutti i nodi:
  -- pile alte a monte non devono invertire i rami alla seconda esecuzione.
  local info = {}
  for i, c in ipairs(comps) do
    local sy, sx, n = 0, 0, 0
    for _, t in ipairs(c) do
      if #edges[t] == 0 then
        local x, y = flow:GetPos(t)
        sy = sy + (y or 0); sx = sx + (x or 0); n = n + 1
      end
    end
    info[i] = { c = c, avgY = n > 0 and sy / n or 0,
      avgX = n > 0 and sx / n or 0, index = i }
  end
  table.sort(info, function(a, b)
    if a.avgY ~= b.avgY then return a.avgY < b.avgY end
    if a.avgX ~= b.avgX then return a.avgX < b.avgX end
    return a.index < b.index
  end)

  -- La prima componente conserva la X del sink più a destra.
  -- Le altre conservano la propria ancora se non invadono la precedente;
  -- altrimenti trasliamo tutta la componente (mai ribaltare il flow).
  local allPos = {}
  local cursor, totalWidth = nil, 0
  for _, inf in ipairs(info) do
    local pos, width, anchorX = layoutComponent(inf.c, edges, redges, inName, imageInputs, maskEdge, flow)
    local offset = anchorX
    if cursor then offset = math.max(offset, cursor + width) end
    for t, p in pairs(pos) do
      allPos[t] = { X = p.X + offset, Y = p.Y }
    end
    cursor = offset + NODE_W + COMP_GAP
    totalWidth = totalWidth + width + NODE_W + COMP_GAP
  end

  comp:StartUndo("NodeAlign")
  for t, p in pairs(allPos) do
    flow:SetPos(t, p.X, p.Y)
  end
  comp:EndUndo(true)
  print(string.format("[NodeAlign] componenti: %d, ingombro complessivo: %.1f unità",
    #info, totalWidth - COMP_GAP))
  print("[NodeAlign] posizioni applicate")
end

--==============================================================
-- Punti d'ingresso
--==============================================================

function NodeAlignAll()
  local comp = fu:GetCurrentComp()
  if not comp then print("[NodeAlign] comp nil") return end
  comp:Lock()
  local ok, err = pcall(function()
    local tools = {}
    for _, t in ipairs(collectTools(comp, false)) do
      if topLevelTool(t) == t then table.insert(tools, t) end
    end
    layoutTools(comp, tools, "Align All")
  end)
  comp:Unlock()
  if not ok then print("[NodeAlign] ERRORE: " .. tostring(err)) end
end

function NodeAlignSelected()
  local comp = fu:GetCurrentComp()
  if not comp then print("[NodeAlign] comp nil") return end
  comp:Lock()
  local ok, err = pcall(function()
    local flow, sel = getFlow(comp), {}
    for _, t in ipairs(collectTools(comp, true)) do
      if topLevelTool(t) == t and flow:GetPos(t) ~= nil then sel[#sel + 1] = t end
    end
    if #sel == 0 then print("[NodeAlign] seleziona almeno un nodo nel flow") return end
    -- Espandi a monte nel grafo VISIBILE, senza entrare in Macro/Group.
    local all = collectTools(comp, false)
    local inSet = {}
    for _, t in ipairs(all) do
      if topLevelTool(t) == t and flow:GetPos(t) ~= nil then inSet[t] = true end
    end
    local set, stack = {}, {}
    for _, t in ipairs(sel) do stack[#stack + 1] = t end
    while #stack > 0 do
      local t = table.remove(stack)
      if not set[t] then
        set[t] = true
        for _, inp in pairs(t:GetInputList() or {}) do
          local okd, dt = pcall(function() return inp:GetAttrs().INPS_DataType end)
          if okd and validTypes[dt] then
            local oOk, out = pcall(function() return inp:GetConnectedOutput() end)
            if oOk and out then
              local sOk, src = pcall(function() return out:GetTool() end)
              if sOk and src then src = topLevelTool(src) end
              if sOk and src and inSet[src] and not set[src] then
                stack[#stack + 1] = src
              end
            end
          end
        end
      end
    end
    local tools = {}
    for t in pairs(set) do table.insert(tools, t) end
    layoutTools(comp, tools, "Align Selected Tree")
  end)
  comp:Unlock()
  if not ok then print("[NodeAlign] ERRORE: " .. tostring(err)) end
end

function NodeAlignFixOverlaps()
  local comp = fu:GetCurrentComp()
  if not comp then print("[NodeAlign] comp nil") return end
  comp:Lock()
  local ok, err = pcall(function()
    local flow = getFlow(comp)
    local list = {}
    for _, t in ipairs(collectTools(comp, false)) do
      local x, y = flow:GetPos(t)
      if x ~= nil and topLevelTool(t) == t then
        table.insert(list, { t = t, X = x, Y = y })
      end
    end
    table.sort(list, function(a, b)
      if a.X ~= b.X then return a.X > b.X end
      if a.Y ~= b.Y then return a.Y < b.Y end
      return tostring(a.t.Name or a.t) < tostring(b.t.Name or b.t)
    end)
    local placed, moved = {}, 0
    comp:StartUndo("NodeAlign Fix Overlaps")
    for _, p in ipairs(list) do
      local y = freeY(p.X, p.Y, placed)
      if y ~= p.Y then
        p.Y = y
        flow:SetPos(p.t, p.X, p.Y)
        moved = moved + 1
      end
      placed[#placed + 1] = p
    end
    comp:EndUndo(true)
    print(string.format("[NodeAlign] Fix Overlaps: %d nodi spostati", moved))
  end)
  comp:Unlock()
  if not ok then print("[NodeAlign] ERRORE: " .. tostring(err)) end
end

print("[NodeAlign] caricato v6 (dorsale orizzontale, rami laterali separati)")

-- Test del vero script tramite mock dell'API Fusion (nessun Resolve necessario).
local source = assert(NODEALIGN_SOURCE, "impostare NODEALIGN_SOURCE")
local logs = {}
local realPrint = print
print = function(...) local s = {}; for i = 1, select('#', ...) do s[i] = tostring(select(i, ...)) end; logs[#logs + 1] = table.concat(s, ' ') end
dofile(source)

local EXPECTED_PITCH_Y = 1.75
local function near(a, b) assert(math.abs(a - b) < 1e-6, tostring(a) .. ' ~= ' .. tostring(b)) end
local function tool(name, x, y, id)
  local t = {Name = name, ID = id or 'Filter', x = x, y = y, inputs = {}}
  function t:GetInputList() return self.inputs end
  return t
end
local function link(src, dst, name, dt, key)
  local input = {}
  function input:GetAttrs() return {INPS_ID = name or 'Input', INPS_DataType = dt or 'Image'} end
  function input:GetConnectedOutput() return {GetTool = function() return src end} end
  dst.inputs[key or (#dst.inputs + 1)] = input
end
local function setup(tools, selected, sparse)
  logs = {}
  local comp = {locked = 0, undo = 0, writes = 0}
  local flow = {}
  function flow:GetPos(t) return t.x, t.y end
  function flow:SetPos(t, x, y) t.x, t.y = x, y; comp.writes = comp.writes + 1 end
  function comp:GetFrameList() return {{FlowView = flow}} end
  function comp:GetToolList(sel)
    local list = sel and (selected or {}) or tools
    if not sparse then return list end
    local result = {}; for i, t in ipairs(list) do result[t.Name] = t end; return result
  end
  function comp:Lock() self.locked = self.locked + 1 end
  function comp:Unlock() self.locked = self.locked - 1 end
  function comp:StartUndo() self.undo = self.undo + 1 end
  function comp:EndUndo() self.undo = self.undo - 1 end
  fu = {GetCurrentComp = function() return comp end}
  return comp
end
local function healthy(comp)
  near(comp.locked, 0); near(comp.undo, 0)
  for _, s in ipairs(logs) do assert(not s:find('ERRORE'), s) end
end
local function noOverlaps(tools)
  for i = 1, #tools do for j = i + 1, #tools do
    local a, b = tools[i], tools[j]
    assert(math.abs(a.x - b.x) >= 1.0 - 1e-6 or math.abs(a.y - b.y) >= EXPECTED_PITCH_Y - 1e-6,
      'collisione: ' .. a.Name .. ' / ' .. b.Name)
  end end
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = {name, fn} end

test('catena: sink ancorato e Media a sinistra', function()
  local a, b, s = tool('Media', 5, 2), tool('Blur', 20, 5), tool('Out', 100, 12)
  link(a, b); link(b, s)
  local c = setup({a,b,s}); NodeAlignAll(); healthy(c)
  near(s.x, 100); near(s.y, 12); near(b.x, 98.9); near(a.x, 97.8)
  near(a.y,s.y); near(b.y,s.y) -- leggibilità: niente scala verticale
  noOverlaps({a,b,s})
end)
test('sink con X negativa non ricentrato a zero', function()
  local a, s = tool('Media', 0, 0), tool('Out', -25, -8); link(a,s)
  local c = setup({a,s}); NodeAlignAll(); healthy(c); near(s.x,-25); near(s.y,-8)
  near(a.x,-26.1)
end)
test('ripiego Foreground sotto il Merge senza spostare il sink', function()
  local bg, fg, m = tool('BG', 0, 20), tool('FG', 5, -100), tool('Merge', 50, 7, 'Merge')
  link(bg,m,'Background'); link(fg,m,'Foreground')
  local c = setup({bg,fg,m}); NodeAlignAll(); healthy(c)
  near(m.x,50); near(m.y,7); near(fg.x,m.x); assert(fg.y >= m.y + EXPECTED_PITCH_Y)
  assert(bg.x < m.x); noOverlaps({bg,fg,m})
end)
test('ripiego accessorio limitato a quattro nodi', function()
  local bg, m = tool('BG', 0, 10), tool('Merge', 70, 0, 'Merge')
  local list, prev = {bg,m}, m
  for i=1,6 do local t=tool('FG'..i, i, -i); list[#list+1]=t; link(t,prev,i==1 and 'Foreground' or 'Input'); prev=t end
  -- Background è qui davvero il ramo dominante (8 nodi), non un piatto.
  prev=bg
  for i=1,7 do local t=tool('BG'..i, -i, 10); list[#list+1]=t; link(t,prev); prev=t end
  link(bg,m,'Background')
  local c=setup(list); NodeAlignAll(); healthy(c)
  for i=3,6 do near(list[i].x,m.x) end
  assert(list[7].x < m.x); assert(list[8].x < list[7].x)
  near(bg.y,m.y); noOverlaps(list)
end)
test('Mask su tool mono-immagine non ripiegata', function()
  local a, mask, t = tool('Media',0,0), tool('Mask',0,3), tool('Test',30,4,'Test')
  link(a,t,'Input'); link(mask,t,'EffectMask','Mask')
  local c=setup({a,mask,t}); NodeAlignAll(); healthy(c)
  assert(mask.x < t.x); assert(a.x < t.x); near(t.y,4)
end)
test('EffectMask su Merge ripiegata', function()
  local a, mask, m = tool('Media',0,0), tool('Mask',0,3), tool('Merge',30,4,'Merge')
  link(a,m,'Background'); link(mask,m,'EffectMask','Mask')
  local c=setup({a,mask,m}); NodeAlignAll(); healthy(c); near(mask.x,m.x); assert(mask.y>m.y)
end)
test('due input immagine su giunzione non-Merge', function()
  local a, b, t=tool('A',0,0),tool('B',2,2),tool('Junction',30,5,'Composite')
  link(a,t,'Background'); link(b,t,'Foreground')
  local c=setup({a,b,t}); NodeAlignAll(); healthy(c); near(b.x,t.x); assert(a.x<t.x)
end)
test('stessa sorgente su input principale e secondario: prevale principale', function()
  for _, reverse in ipairs({false,true}) do
    local a,m=tool('A',0,0),tool('Merge',30,5,'Merge')
    link(a,m,reverse and 'Background' or 'Foreground'); link(a,m,reverse and 'Foreground' or 'Background')
    local c=setup({a,m}); NodeAlignAll(); healthy(c); assert(a.x<m.x)
  end
end)
test('fan-out e percorsi di lunghezza diversa', function()
  local a,b,d,s=tool('Source',0,0),tool('B',2,0),tool('D',4,0),tool('Sink',90,2,'Merge')
  link(a,b); link(b,d); link(d,s,'Background'); link(a,s,'Foreground')
  local c=setup({a,b,d,s}); NodeAlignAll(); healthy(c)
  assert(a.x<b.x and b.x<d.x and d.x<s.x); near(s.x,90); near(s.y,2); noOverlaps({a,b,d,s})
end)
test('più sink: Y conservate se non collidono', function()
  local a,s1,s2=tool('A',0,0),tool('S1',20,2),tool('S2',80,20)
  link(a,s1); link(a,s2)
  local c=setup({a,s1,s2}); NodeAlignAll(); healthy(c)
  near(s1.y,2); near(s2.y,20); near(s1.x,80); near(s2.x,80); assert(a.x<80)
end)
test('componenti affiancate senza sovrapposizioni', function()
  local a,s1,b,s2=tool('A',0,0),tool('S1',50,0),tool('B',0,2),tool('S2',50,10)
  link(a,s1); link(b,s2)
  local c=setup({a,s1,b,s2}); NodeAlignAll(); healthy(c)
  near(s1.x,50); near(s1.y,0); near(s2.y,10); assert(b.x>=s1.x+4-1e-6); assert(b.x<s2.x)
  noOverlaps({a,s1,b,s2})
end)
test('ripetizione con componenti di altezze diverse: ordine stabile', function()
  local list={}
  for i=1,20 do list[i]=tool('Tall'..i,i,0); if i>1 then link(list[i-1],list[i]) end end
  local other=tool('Other',20,10); list[#list+1]=other
  local c=setup(list); NodeAlignAll(); healthy(c)
  local old={}; for i,t in ipairs(list) do old[i]={t.x,t.y} end
  NodeAlignAll(); healthy(c)
  for i,t in ipairs(list) do near(t.x,old[i][1]); near(t.y,old[i][2]) end
end)
test('sink sovrapposti: separazione solo quando necessaria', function()
  local a,s1,s2=tool('A',0,0),tool('S1',50,3),tool('S2',50,3)
  link(a,s1); link(a,s2)
  local c=setup({a,s1,s2}); NodeAlignAll(); healthy(c)
  near(s1.y,3); near(s2.y,3 + EXPECTED_PITCH_Y); noOverlaps({a,s1,s2})
end)
test('Selected Tree: selezione ancorata, downstream e altri rami intatti', function()
  local a,b,out,other=tool('A',0,0),tool('Selected',44,8),tool('Out',60,1),tool('Other',-3,-4)
  link(a,b); link(b,out)
  local c=setup({a,b,out,other},{b}); NodeAlignSelected(); healthy(c)
  near(b.x,44); near(b.y,8); assert(a.x<b.x); near(out.x,60); near(out.y,1); near(other.x,-3); near(other.y,-4)
end)
test('liste API associative, modifier esclusi', function()
  local a,s,modifier=tool('A',0,0),tool('Out',22,5),tool('Spline',nil,nil)
  link(a,s,'Input','Image','Input')
  local c=setup({a,s,modifier},{s},true); NodeAlignAll(); healthy(c)
  near(s.x,22); assert(a.x<s.x); assert(modifier.x==nil); near(c.writes,2)
end)
test('ripetizione layout non sposta il sink e stabilizza la catena', function()
  local a,b,s=tool('A',0,0),tool('B',2,1),tool('S',100,7)
  link(a,b); link(b,s)
  local c=setup({a,b,s}); NodeAlignAll(); healthy(c)
  local old={a.x,a.y,b.x,b.y,s.x,s.y}; NodeAlignAll(); healthy(c)
  for i,v in ipairs({a.x,a.y,b.x,b.y,s.x,s.y}) do near(v,old[i]) end
end)
test('ciclo rilevato: niente scritture e lock rilasciato', function()
  local a,b,s=tool('A',0,0),tool('B',2,1),tool('S',50,7)
  link(a,b); link(b,a); link(b,s)
  local c=setup({a,b,s}); NodeAlignAll(); near(c.writes,0); near(c.locked,0); near(c.undo,0)
  assert(table.concat(logs,' '):find('ciclo nel grafo'))
end)
test('Fix Overlaps: X intatte, sink destro fermo, risultato stabile', function()
  local a,b,s=tool('A',10,5),tool('B',10.4,5),tool('S',10.8,5)
  local c=setup({a,b,s}); NodeAlignFixOverlaps(); healthy(c)
  near(a.x,10); near(b.x,10.4); near(s.x,10.8); near(s.y,5); noOverlaps({a,b,s})
  local n=c.writes; NodeAlignFixOverlaps(); healthy(c); near(c.writes,n)
end)
test('grafo vuoto e selezione vuota', function()
  local c=setup({}); NodeAlignAll(); NodeAlignSelected(); healthy(c); near(c.writes,0)
end)
test('catena profonda senza ricorsione', function()
  local list={}
  for i=1,1500 do list[i]=tool('T'..i,i,0); if i>1 then link(list[i-1],list[i]) end end
  local c=setup(list); NodeAlignAll(); healthy(c); near(list[1500].x,1500); near(list[1500].y,0)
  for i=1,1499 do assert(list[i].x<list[i+1].x); near(list[i].y,0) end
  c=setup(list,{list[1500]}); NodeAlignSelected(); healthy(c)
  near(c.writes,1500); near(list[1500].x,1500); near(list[1500].y,0)
end)

test('Foreground può essere dorsale: un Background piatto non la ripiega', function()
  local list, spine = {}, {}
  local prev
  for i=1,8 do
    local t=tool('Content'..i,i,-i); list[#list+1]=t; spine[#spine+1]=t
    if prev then link(prev,t) end; prev=t
  end
  local bg,m,out=tool('FlatBG',0,0),tool('Merge',30,2,'Merge'),tool('Out',40,6)
  list[#list+1]=bg; list[#list+1]=m; list[#list+1]=out
  link(bg,m,'Background'); link(prev,m,'Foreground'); link(m,out)
  local c=setup(list); NodeAlignAll(); healthy(c)
  near(out.x,40); near(out.y,6); near(m.y,6)
  for _,t in ipairs(spine) do near(t.y,6); assert(t.x<m.x) end
  near(bg.x,m.x); assert(bg.y>m.y); noOverlaps(list)
end)
test('Merge in cascata su Foreground: nessun ripiego della dorsale', function()
  local source=tool('Media',0,0); local list,main={source},{source}; local prev=source
  for i=1,9 do
    local bg,m=tool('BG'..i,0,i),tool('Merge'..i,i,-i,'Merge')
    link(bg,m,'Background'); link(prev,m,'Foreground')
    list[#list+1]=bg; list[#list+1]=m; main[#main+1]=m; prev=m
  end
  local out=tool('Out',60,5); link(prev,out); list[#list+1]=out
  local c=setup(list); NodeAlignAll(); healthy(c)
  -- La prima giunzione è in parità: BG1 vince, ma tutte le giunzioni
  -- successive continuano su Foreground e devono rimanere orizzontali.
  for i=2,#main do near(main[i].y,out.y); if i>2 then assert(main[i].x>main[i-1].x) end end
  noOverlaps(list)
end)
test('Macro/Group atomici: output interno normalizzato, child mai spostati', function()
  for _,selected in ipairs({false,true}) do
    local a,g,nested,child,b,out=tool('Media',0,0),tool('Group',10,3,'GroupOperator'),
      tool('Nested',20,8,'MacroOperator'),tool('InternalOutput',30,9),tool('Filter',40,10),tool('Out',50,7)
    nested.ParentTool=g; child.ParentTool=nested
    link(a,g); link(a,child); link(child,b); link(b,out)
    local list={a,g,nested,child,b,out}; local c=setup(list,{out})
    if selected then NodeAlignSelected() else NodeAlignAll() end; healthy(c)
    near(c.writes,4); near(child.x,30); near(child.y,9); near(nested.x,20); near(nested.y,8)
    assert(a.x<g.x and g.x<b.x and b.x<out.x)
    for _,t in ipairs({a,g,b,out}) do near(t.y,out.y) end
    noOverlaps({a,g,b,out})
  end
end)
test('Fix Overlaps non deforma una catena con passo 1.1', function()
  local a,b,s=tool('A',10,5),tool('B',11.1,5),tool('S',12.2,5)
  local c=setup({a,b,s}); NodeAlignFixOverlaps(); healthy(c); near(c.writes,0)
end)
test('grafo reale S08: dorsale orizzontale, giunzioni non ripiegate, compattezza', function()
  local fixture=assert(FUSION_FIXTURE,'fixture del grafo reale mancante')
  local list,byName={},{}
  for _,node in ipairs(fixture.nodes) do
    local t=tool(node.name,node.x,node.y,node.type); list[#list+1]=t; byName[t.Name]=t
  end
  for _,node in ipairs(fixture.nodes) do for _,inp in ipairs(node.inputs) do
    if byName[inp.source] then link(byName[inp.source],byName[node.name],inp.id,inp.type) end
  end end
  local out=byName.MediaOut1
  local c=setup(list,{out}); NodeAlignSelected(); healthy(c)
  near(out.x,15); near(out.y,1.009)
  local names={'S08_Yacht','S08_YachtXF','S08_YachtM','Merge7','Merge6','S08_Top','MediaOut1'}
  for i,name in ipairs(names) do
    local t=byName[name]; near(t.y,out.y)
    if i>1 then assert(t.x>byName[names[i-1]].x) end
  end
  local active={}; local visited={}
  local function add(t)
    if visited[t] then return end; visited[t]=true; active[#active+1]=t
    for _,inp in pairs(t.inputs) do add(inp:GetConnectedOutput():GetTool()) end
  end
  add(out); noOverlaps(active); near(c.writes,#active)
  local minY,maxY=math.huge,-math.huge
  for _,t in ipairs(active) do minY=math.min(minY,t.y); maxY=math.max(maxY,t.y) end
  -- 23 nodi, due percorsi immagine e tre asset nella stessa colonna:
  -- budget di sei passi verticali, non una torre proporzionale al grafo.
  assert(maxY-minY<=6 * EXPECTED_PITCH_Y + 1e-6,'grafo ancora troppo alto: '..(maxY-minY))
  for _,name in ipairs({'S08_YachtM','Merge7','Merge6','S08_Top','S08_LogoM','S08_P1M','S08_P2M','S08_P3M'}) do
    local t=byName[name]
    for _,inp in pairs(t.inputs) do
      if inp:GetAttrs().INPS_DataType~='Mask' then
        local src=inp:GetConnectedOutput():GetTool()
        if src.ID=='Merge' then assert(src.x<t.x,'giunzione ripiegata: '..src.Name) end
      end
    end
  end
  near(byName.S08_P2.y-byName.S08_P2M.y,EXPECTED_PITCH_Y)
  near(byName.S08_P3.y-byName.S08_P3M.y,EXPECTED_PITCH_Y)
  near(byName.S08_LogoXF.y-byName.S08_LogoM.y,EXPECTED_PITCH_Y)
  -- Una mask può precedere una pila, ma non interromperne la catena.
  near(byName.ColorCorrector1.y-byName.S08_PhotoXF.y,EXPECTED_PITCH_Y)
  near(byName.S08_Photo.y-byName.ColorCorrector1.y,EXPECTED_PITCH_Y)
  near(byName.S08_Logo.y-byName.S08_LogoXF.y,EXPECTED_PITCH_Y)
  FUSION_PREVIEW={}
  for _,t in ipairs(active) do
    local inputs={}
    for _,inp in pairs(t.inputs) do
      inputs[#inputs+1]={source=inp:GetConnectedOutput():GetTool().Name,id=inp:GetAttrs().INPS_ID}
    end
    FUSION_PREVIEW[#FUSION_PREVIEW+1]={name=t.Name,x=t.x,y=t.y,inputs=inputs}
  end
  -- Controlla anche la stabilità, non solo le collisioni.
  local old={}; for _,t in ipairs(active) do old[t]={t.x,t.y} end
  NodeAlignSelected(); healthy(c)
  for _,t in ipairs(active) do near(t.x,old[t][1]); near(t.y,old[t][2]) end
end)

test('50 DAG generati: flusso verso destra, sink ancorati, nessuna collisione', function()
  math.randomseed(2026)
  for case=1,50 do
    local list={}
    for i=1,35 do list[i]=tool('N'..i,math.random(-50,50),math.random(-20,20),i%7==0 and 'Merge' or 'Filter') end
    list[35].x,list[35].y=100,5
    for i=1,34 do
      local target=math.random(i+1,35)
      link(list[i],list[target],i%3==0 and 'Foreground' or 'Background')
      if i%5==0 then local d=math.random(i+1,35); link(list[i],list[d],'Background') end
    end
    local c=setup(list); NodeAlignAll(); healthy(c); near(list[35].x,100); near(list[35].y,5)
    noOverlaps(list)
    for _,t in ipairs(list) do for _,inp in pairs(t.inputs) do
      local src=inp:GetConnectedOutput():GetTool(); assert(src.x<=t.x+1e-6)
    end end
  end
end)

local failed=0
for _, t in ipairs(tests) do
  local ok, err=pcall(t[2])
  realPrint((ok and 'PASS ' or 'FAIL ')..t[1]..(ok and '' or ': '..tostring(err)))
  if not ok then failed=failed+1 end
end
print=realPrint
assert(failed==0, failed..' / '..#tests..' test falliti')
realPrint('OK: '..#tests..' test')

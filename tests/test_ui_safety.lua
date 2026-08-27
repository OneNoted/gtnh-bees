local H=require("tests.harness")
local Application=require("gtnh_bees.application")
local Menu=require("gtnh_bees.menu")

local function assert_no_false_safe_phrase(lines)
  H.falsy(table.concat(lines,"\n"):find("Operation stopped safely",1,true),"TUI must not claim an unknown failure stopped safely")
end

local function run_tui(execute,answers,events)
  local original_read,original_write,original_print=io.read,io.write,_G.print
  local lines,pulls,reads={},0,0
  local keys={up=1,down=2,enter=3,q=4,esc=5,back=6}
  io.read=function()
    reads=reads+1
    local value=table.remove(answers,1)
    if value==nil then error("unexpected TUI read") end
    return value
  end
  io.write=function()return true end
  _G.print=function(value)lines[#lines+1]=tostring(value)end
  local runtime={
    term={clear=function()end},
    keyboard={keys=keys},
    event={pull=function()
      pulls=pulls+1
      local code=table.remove(events,1)
      if code==nil then error("TUI requested another event after its test budget") end
      return "key_down",nil,nil,code
    end}
  }
  local call_ok,menu_ok,menu_err,metadata=pcall(function()return Menu.run(execute,runtime)end)
  io.read,io.write,_G.print=original_read,original_write,original_print
  return call_ok,menu_ok,menu_err,metadata,lines,pulls,reads
end

H.test("application classifies factory failure as not started",function()
  local app=Application.new(function()return nil,"configuration rejected"end,function()end)
  local ok,err,metadata=app:execute({name="complete"})
  H.falsy(ok);H.contains(err,"configuration rejected");H.equal(metadata.safety_state,"not_started")
end)

H.test("application classifies an exception during construction as not started",function()
  local app=Application.new(function()error("topology exploded")end,function()end)
  local ok,err,metadata=app:execute({name="complete"})
  H.falsy(ok);H.contains(err,"topology exploded");H.equal(metadata.safety_state,"not_started")
end)

H.test("application classifies no operation result after construction as unknown",function()
  local adapter={recover_pending=function()return nil,"ambiguous machine output"end}
  local app=Application.new(function()return adapter,{archive_size=32}end,function()end)
  local ok,err,metadata=app:execute({name="complete"})
  H.falsy(ok);H.contains(err,"ambiguous machine output");H.equal(metadata.safety_state,"unknown")
end)

H.test("application does not infer safety from operation error wording",function()
  local adapter={recover_pending=function()return nil,"run stopped safely"end}
  local app=Application.new(function()return adapter,{archive_size=32}end,function()end)
  local ok,_,metadata=app:execute({name="complete"})
  H.falsy(ok);H.equal(metadata.safety_state,"unknown")
end)

H.test("application preserves reconciled safety for rejected species input",function()
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=2,reserved_slot=2,bees={}}end,
    list_species=function()return{{uid="a",name="Known Bee"}}end,
    list_mutations=function()return{}end
  }
  local app=Application.new(function()return adapter,{archive_size=32}end,function()end)
  local ok,err,metadata=app:execute({name="breed",species="unknown",imprint="none"})
  H.falsy(ok);H.contains(err,"unknown species");H.equal(metadata.safety_state,"known_safe")
end)

H.test("application invalidates reconciled safety before physical production",function()
  local function bee(caste,uid,slot)
    return{caste=caste,active=uid,inactive=uid,scanned=true,size=1,maxSize=64,genome={uid=uid},inventory="bee_storage",slot=slot}
  end
  local stock={bee("princess","a",1),bee("drone","a",2),bee("princess","b",3),bee("drone","b",4)}
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=6,reserved_slot=6,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c",name="Target"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=100}}end,
    produce_species=function()return nil,"breeder vanished"end
  }
  local app=Application.new(function()return adapter,{archive_size=32}end,function()end)
  local ok,err,metadata=app:execute({name="breed",species="Target",imprint="none"})
  H.falsy(ok);H.contains(err,"breeder vanished");H.equal(metadata.safety_state,"unknown")
end)

H.test("full TUI locks after structured unknown physical failure",function()
  local calls=0
  local call_ok,menu_ok,menu_err,metadata,lines,pulls,reads=run_tui(function()
    calls=calls+1
    return nil,"adapter vanished",{safety_state="unknown"}
  end,{"y"},{3,3})
  H.truthy(call_ok,menu_err);H.falsy(menu_ok);H.contains(menu_err,"adapter vanished")
  H.equal(metadata.safety_state,"unknown");H.equal(calls,1);H.equal(pulls,1);H.equal(reads,1)
  local output=table.concat(lines,"\n")
  H.contains(output,"PHYSICAL STATE UNPROVEN: adapter vanished")
  H.contains(output,"Menu locked")
  assert_no_false_safe_phrase(lines)
end)

H.test("full TUI treats unstructured execution failure as unknown and locks",function()
  local calls=0
  local call_ok,menu_ok,menu_err,metadata,lines,pulls=run_tui(function()
    calls=calls+1
    return nil,"legacy failure without safety metadata"
  end,{"y"},{3,3})
  H.truthy(call_ok,menu_err);H.falsy(menu_ok);H.contains(menu_err,"legacy failure")
  H.equal(metadata.safety_state,"unknown");H.equal(calls,1);H.equal(pulls,1)
  H.contains(table.concat(lines,"\n"),"PHYSICAL STATE UNPROVEN")
  assert_no_false_safe_phrase(lines)
end)

H.test("full TUI permits return after not-started failure",function()
  local calls=0
  local call_ok,menu_ok,menu_err,_,lines,pulls,reads=run_tui(function()
    calls=calls+1
    return nil,"configuration rejected",{safety_state="not_started"}
  end,{"y",""},{3,4})
  H.truthy(call_ok,menu_err);H.truthy(menu_ok);H.equal(calls,1);H.equal(pulls,2);H.equal(reads,2)
  H.contains(table.concat(lines,"\n"),"Operation did not start; no physical movement began: configuration rejected")
  assert_no_false_safe_phrase(lines)
end)

H.test("full TUI permits return after known-safe incomplete outcome",function()
  local calls=0
  local call_ok,menu_ok,menu_err,_,lines,pulls,reads=run_tui(function()
    calls=calls+1
    return nil,"one requested target remains",{operation="complete",success=false,safety_state="known_safe"}
  end,{"y",""},{3,4})
  H.truthy(call_ok,menu_err);H.truthy(menu_ok);H.equal(calls,1);H.equal(pulls,2);H.equal(reads,2)
  H.contains(table.concat(lines,"\n"),"Operation did not complete; physical state is known safe: one requested target remains")
  assert_no_false_safe_phrase(lines)
end)

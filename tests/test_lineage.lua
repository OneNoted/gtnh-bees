local H=require("tests.harness")
local Operations=require("gtnh_bees.operations")
local util=require("gtnh_bees.util")

local function bee(caste,uid,slot,size,genome)
  return {caste=caste,active=uid,inactive=uid,scanned=true,size=size or 1,maxSize=64,
    genome=genome or {uid=uid},inventory="bee_storage",slot=slot}
end

local function complete_adapter(fail_target)
  local stock={}
  local by_uid={}
  local slot=0
  for _,uid in ipairs({"a","b","d"})do
    slot=slot+1
    local princess=bee("princess",uid,slot)
    slot=slot+1
    local drone=bee("drone",uid,slot,32)
    stock[#stock+1],stock[#stock+2]=princess,drone
    by_uid[uid]={princess=princess,drone=drone}
  end
  local donor=bee("drone","a",29,1,{mark="template"})
  local template=bee("drone","template",30,1,{mark="template"})
  stock[#stock+1],stock[#stock+2]=donor,template
  local events={}
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=30,reserved_slot=30,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"},{uid="d"},{uid="e"}}end,
    list_mutations=function()return{
      {result="c",parents={"a","b"},chance=100},
      {result="e",parents={"c","d"},chance=100}
    }end,
    produce_species=function(_,step)
      events[#events+1]="produce:"..step.uid
      if fail_target==step.uid then
        return{safe=true,complete=false,uid=step.uid,location="bee_storage",outputs={},route_failure="deterministic",error="hostile route stop"}
      end
      slot=slot+1
      local princess=bee("princess",step.uid,slot)
      slot=slot+1
      local drone=bee("drone",step.uid,slot)
      stock[#stock+1],stock[#stock+2]=princess,drone
      by_uid[step.uid]={princess=princess,drone=drone}
      return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={princess,drone}}
    end,
    expand_archive=function(_,uid)
      events[#events+1]="archive:"..uid
      by_uid[uid].drone.size=32
      return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={by_uid[uid].drone}}
    end,
    imprint_one=function(_,uid)
      events[#events+1]="imprint:"..uid
      return{safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}
    end
  }
  return adapter,events
end

H.test("complete queues every imprint until all reachable targets are archived",function()
  local adapter,events=complete_adapter()
  local outcome=assert(Operations.new(adapter,{limits={progress=12,archive=2,imprint=2}}):complete({imprint="all"}))
  H.truthy(outcome.success)
  H.equal(events,{"produce:c","archive:c","produce:e","archive:e","imprint:a","imprint:b","imprint:d","imprint:c","imprint:e"})
end)

H.test("complete reopens and replenishes an archive consumed by later production",function()
  local a_princess=bee("princess","a",1)
  local a_drone=bee("drone","a",2,32)
  local b_princess,b_drone
  local stock={a_princess,a_drone}
  local events={}
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"}}end,
    list_mutations=function()return{{result="b",parents={"a","a"},chance=100}}end,
    produce_species=function(_,step)
      events[#events+1]="produce:"..step.uid
      a_drone.size=a_drone.size-1
      b_princess,b_drone=bee("princess","b",3),bee("drone","b",4)
      stock[#stock+1],stock[#stock+2]=b_princess,b_drone
      return{safe=true,complete=true,uid="b",location="bee_storage",outputs={b_princess,b_drone}}
    end,
    expand_archive=function(_,uid)
      events[#events+1]="archive:"..uid
      local drone=uid=="a" and a_drone or b_drone
      drone.size=32
      return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={drone}}
    end
  }
  local outcome=assert(Operations.new(adapter,{limits={progress=6,archive=2}}):complete({imprint="none"}))
  H.truthy(outcome.success)
  H.equal(events,{"produce:b","archive:a","archive:b"})
  H.equal(a_drone.size,32)
end)

H.test("complete and breed prepare surplus before spending a protected mutation parent",function()
  local function fixture()
    local parent=bee("drone","a",2,32)
    local stock={bee("princess","a",1),parent}
    local target_drone
    local events={}
    return {
      requires_mutation_surplus=true,
      recover_pending=function()return{}end,
      snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
      list_species=function()return{{uid="a"},{uid="c",name="C"}}end,
      list_mutations=function()return{{result="c",parents={"a","a"},chance=100}}end,
      expand_archive=function(_,uid,target)
        events[#events+1]="archive:"..uid..":"..target
        local drone=uid=="a"and parent or target_drone
        drone.size=target
        return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={drone}}
      end,
      produce_species=function(_,step,minimum)
        H.equal(minimum,32);H.equal(parent.size,33)
        events[#events+1]="produce:"..step.uid
        parent.size=parent.size-1
        target_drone=bee("drone","c",4)
        stock[#stock+1]=bee("princess","c",3)
        stock[#stock+1]=target_drone
        return{safe=true,complete=true,uid="c",location="bee_storage",outputs={stock[#stock-1],target_drone}}
      end
    },events,parent
  end

  local complete_adapter,complete_events,complete_parent=fixture()
  local completed=assert(Operations.new(complete_adapter,{limits={progress=4,archive=2}}):complete({imprint="none"}))
  H.truthy(completed.success);H.equal(complete_events,{"archive:a:33","produce:c","archive:c:32"});H.equal(complete_parent.size,32)

  local breed_adapter,breed_events,breed_parent=fixture()
  local bred=assert(Operations.new(breed_adapter,{limits={progress=4,archive=2}}):breed({species="C",imprint="none",pause=false}))
  H.truthy(bred.success);H.equal(breed_events,{"archive:a:33","produce:c","archive:c:32"});H.equal(breed_parent.size,32)
end)

H.test("complete revalidates every archive after the final progress action",function()
  local a_drone=bee("drone","a",2,32)
  local stock={bee("princess","a",1),a_drone}
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"}}end,
    list_mutations=function()return{{result="b",parents={"a","a"},chance=100}}end,
    produce_species=function()
      a_drone.size=a_drone.size-1
      stock[#stock+1]=bee("princess","b",3)
      stock[#stock+1]=bee("drone","b",4)
      return{safe=true,complete=true,uid="b",location="bee_storage",outputs={stock[3],stock[4]}}
    end
  }
  local outcome=assert(Operations.new(adapter,{limits={progress=1}}):complete({imprint="none"}))
  H.falsy(outcome.success)
  H.equal(outcome.completed,{})
  H.equal(#outcome.missing,2)
  H.equal(outcome.missing[1].uid,"a")
  H.equal(outcome.missing[2].uid,"b")
end)

H.test("standalone breeding restores every completed parent archive",function()
  local a_drone=bee("drone","a",2,32)
  local b_drone=bee("drone","b",4,32)
  local c_drone
  local stock={bee("princess","a",1),a_drone,bee("princess","b",3),b_drone}
  local restored={}
  local adapter={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c",name="C"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=100}}end,
    produce_species=function(_,_,archive_minimum)
      H.equal(archive_minimum,32)
      a_drone.size=a_drone.size-1
      c_drone=bee("drone","c",6)
      stock[#stock+1]=bee("princess","c",5)
      stock[#stock+1]=c_drone
      return{safe=true,complete=true,uid="c",location="bee_storage",outputs={stock[#stock-1],c_drone}}
    end,
    expand_archive=function(_,uid)
      restored[#restored+1]=uid
      local drone=uid=="a"and a_drone or uid=="b"and b_drone or c_drone
      drone.size=32
      return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={drone}}
    end
  }
  local outcome=assert(Operations.new(adapter,{limits={progress=4,archive=2}}):breed({species="C",imprint="none",pause=false}))
  H.truthy(outcome.success)
  H.equal(restored,{"c","a"})
  H.equal(a_drone.size,32)
  H.equal(b_drone.size,32)
end)

H.test("incomplete complete mode consumes no queued imprint stock",function()
  local adapter,events=complete_adapter("c")
  local outcome=assert(Operations.new(adapter,{limits={progress=8,archive=2,imprint=2}}):complete({imprint="all"}))
  H.falsy(outcome.success)
  H.equal(#outcome.missing,2)
  H.equal(outcome.imprints,{})
  for _,event in ipairs(events)do H.falsy(event:find("imprint:",1,true))end
end)

H.test("complete reports exact-lineage imprint misses nonfatally after target completion",function()
  local princess=bee("princess","a",1)
  local drone=bee("drone","a",2,32)
  local donor=bee("drone","a",3,1,{mark="template"})
  local template=bee("drone","template",4,1,{mark="template"})
  local calls=0
  local adapter={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,drone,donor,template}}end,
    list_species=function()return{{uid="a",name="A"}}end,list_mutations=function()return{}end,
    imprint_one=function(_,uid)
      calls=calls+1
      return{safe=true,complete=false,uid=uid,scanned=false,template_retained=true,location="bee_storage",retained_princess=util.copy(princess),error="ordinary graded miss"}
    end}
  local outcome=assert(Operations.new(adapter,{limits={progress=2,imprint=2}}):complete({imprint="all"}))
  H.truthy(outcome.success)
  H.equal(calls,2)
  H.equal(#outcome.imprints,1)
  H.falsy(outcome.imprints[1].ok)
  H.contains(outcome.imprints[1].error,"exceeded 2")
end)

H.test("complete never spends the last protected archive drone as an imprint donor",function()
  local princess=bee("princess","a",1,1,{mark="template"})
  local archive=bee("drone","a",2,32,{mark="template"})
  local template=bee("drone","a",4,1,{mark="template"})
  local calls=0
  local adapter={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,archive,template}}end,
    list_species=function()return{{uid="a",name="A"}}end,list_mutations=function()return{}end,
    imprint_one=function()calls=calls+1;return{safe=true,complete=true,uid="a",scanned=true,template_retained=true,location="bee_storage"}end}
  local outcome=assert(Operations.new(adapter,{limits={progress=2,imprint=2}}):complete({imprint="all"}))
  H.truthy(outcome.success)
  H.equal(calls,0)
  H.equal(archive.size,32)
  H.equal(#outcome.imprints,1)
  H.falsy(outcome.imprints[1].ok)
  H.contains(outcome.imprints[1].error,"protected archive stock")
end)

H.test("standalone imprint protects every observed completed archive without caller hints",function()
  local princess=bee("princess","target",1,1,{mark="target"})
  local archive=bee("drone","unrelated",2,32,{mark="template"})
  local template=bee("drone","template",4,1,{mark="template"})
  local calls=0
  local adapter={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,archive,template}}end,
    list_species=function()return{{uid="target",name="Target"},{uid="unrelated"},{uid="template"}}end,list_mutations=function()return{}end,
    imprint_one=function()calls=calls+1;archive.size=archive.size-1;return{safe=true,complete=true,uid="target",scanned=true,template_retained=true,location="bee_storage"}end}
  local outcome=assert(Operations.new(adapter,{limits={imprint=2}}):imprint({species="Target"}))
  H.falsy(outcome.success)
  H.contains(outcome.error,"protected archive stock")
  H.equal(calls,0)
  H.equal(archive.size,32)
end)

H.test("imprint retries follow changed active identity at the exact retained slot",function()
  local target=bee("princess","a",1,1,{line="original"})
  local duplicate=bee("princess","a",2,1,{line="original"})
  local donor=bee("drone","template",6,1,{mark="template"})
  local template=bee("drone","template",8,1,{mark="template"})
  local stock={target,duplicate,donor,template}
  local calls=0
  local adapter={
    snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    imprint_one=function(_,uid,_,princess)
      calls=calls+1
      if calls==1 then
        H.equal(princess.slot,1)
        target.active,target.inactive,target.genome,target.slot="graded-one","graded-one",{line="graded-one"},3
        return{safe=true,complete=false,uid=uid,scanned=false,template_retained=true,location="bee_storage",retained_princess=util.copy(target),error="ordinary miss"}
      elseif calls==2 then
        H.equal(princess.slot,3)
        H.equal(princess.active,"graded-one")
        target.active,target.inactive,target.genome,target.slot="graded-two","graded-two",{line="graded-two"},4
        return{safe=true,complete=false,uid=uid,scanned=false,template_retained=true,location="bee_storage",retained_princess=util.copy(target),error="ordinary miss"}
      end
      H.equal(princess.slot,4)
      H.equal(princess.active,"graded-two")
      return{safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}
    end
  }
  local outcome=assert(Operations.new(adapter,{limits={imprint=3}}):optional_imprint("a"))
  H.equal(outcome.generations,3)
  H.equal(calls,3)
end)

H.test("safe incomplete imprint without retained evidence is fatal",function()
  local target=bee("princess","a",1)
  local donor=bee("drone","template",2,1,{mark="template"})
  local template=bee("drone","template",4,1,{mark="template"})
  local calls=0
  local adapter={snapshot_storage=function()return{size=4,reserved_slot=4,bees={target,donor,template}}end,
    imprint_one=function(_,uid)calls=calls+1;return{safe=true,complete=false,uid=uid,scanned=false,template_retained=true,location="bee_storage",error="ordinary miss"}end}
  local value,err,safe=Operations.new(adapter,{limits={imprint=3}}):optional_imprint("a")
  H.falsy(value)
  H.falsy(safe)
  H.contains(err,"exact ordinary bee_storage slot")
  H.equal(calls,1)
end)

H.test("ambiguous reserved stacked and mismatched imprint lineage evidence is fatal",function()
  for _,kind in ipairs({"ambiguous","reserved","stacked","mismatched"})do
    local target=bee("princess","a",1,1,{line="original"})
    local donor=bee("drone","template",6,1,{mark="template"})
    local template=bee("drone","template",8,1,{mark="template"})
    local stock={target,donor,template}
    local adapter={snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
      imprint_one=function(_,uid)
        target.slot=3
        local evidence=util.copy(target)
        if kind=="ambiguous" then stock[#stock+1]=util.copy(target)
        elseif kind=="reserved" then evidence.slot=8
        elseif kind=="stacked" then evidence.size=2
        elseif kind=="mismatched" then target.genome={line="other"} end
        return{safe=true,complete=false,uid=uid,scanned=false,template_retained=true,location="bee_storage",retained_princess=evidence,error="ordinary miss"}
      end}
    local value,err,safe=Operations.new(adapter,{limits={imprint=2}}):optional_imprint("a")
    H.falsy(value,kind)
    H.falsy(safe,kind)
    H.contains(err,"retained target princess")
  end
end)

H.test("operations reject infinite and NaN conversion counts",function()
  local princess=bee("princess","b",1)
  local drone=bee("drone","a",2)
  local calls=0
  local adapter={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,drone}}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function()calls=calls+1 end}
  for _,count in ipairs({math.huge,-math.huge,0/0})do
    local value,err=Operations.new(adapter,{limits={conversion=2}}):convert({species="A",count=count,all=false})
    H.falsy(value)
    H.contains(err,"finite positive integer")
  end
  H.equal(calls,0)
end)

return true

module Solver 
  using DanaTypes
  using Calculus
  using Roots
  export solve!
  import DanaTypes.setfield
  include ("Replace.jl")
  include ("Analysis.jl")
  include ("Update.jl")
  
  #replace known arguments in _eq::Function argument list and returns another function with only unknowns 
  #for unknown arguments pass NaN in _argsArray
  #getEq([1.1,2.3,NaN,-3.1,NaN],fun) -> _fun(arg1,arg2)=fun(1.1,2.3,arg1,-3.1,arg2)

  #=	function getEq(_argsArray::Vector,_eq::Function)
    ex=:((argsArray)->$_eq())
    exx=[_eq]
    len=length(_argsArray)
    j=1
    for i in 1:len
      if isnan(_argsArray[i])
        exx=vcat(exx,:(argsArray[$j]))
        j+=1
      else
        exx=vcat(exx,_argsArray[i])
      end
    end
    ex.args[2].args[2].args=exx
    return eval(ex)
  end =#

  getfield(danamodel::DanaModel,sy::Symbol)=get(Base.getfield(danamodel,sy))
  getfield(danamodel::DanaModel,ex::Expr)=getfield(getfield(danamodel,ex.args[1]),ex.args[2].value)

  #solve li plus one nonlinear
  function sliponl!(danamodel::DanaModel)
    nonliArgs::Array{Set{String},1}=Array(Set{String},0)
    nonliFuns::Array{Function,1}=Array(Function,0)
    somethingUpdated=true
    fullDetermined=false
    noliTrys=0
    nonlTrys=0
    while (somethingUpdated && !fullDetermined)
      somethingUpdated,fullDetermined,nonliFuns,nonliArgs,noTrys=slstsubnfd!(danamodel)
      noliTrys+=noTrys
      if !fullDetermined
        somethingUpdated,fullDetermined,noTrys=snleoovobo!(danamodel,nonliFuns,nonliArgs)
        nonlTrys+=noTrys
      end
    end
    return somethingUpdated,fullDetermined,noliTrys,nonlTrys,nonliFuns,nonliArgs
  end
  
  #main loop
  function solve!(danamodel::DanaModel)
    somthingUpdated=true
    fullDetermined=false
    while (somthingUpdated && !fullDetermined)
      somethingUpdated,fullDetermined,noliTrys,nonlTrys,nonliFuns,nonliArgs=sliponl!(danamodel)
      if !fullDetermined
        #somethingUpdated,fullDetermined=ssonle!(danamodel,nonliFuns,nonliArgs)
      end
    end
    return somethingUpdated,fullDetermined,noliTrys,nonlTrys
  end
  
  # solve system of nonlinear equations
  function ssonle!(danamodel::DanaModel,nonliFuns::Array{Function,1},nonliArgs::Array{Set{String},1})
    somthingUpdated=false
    fullDetermined=false
    numberOfEquations=length(nonliFuns)
    noe=2 #number of equations
    while (noe<=numberOfEquations && !somthingUpdated)
      eqIndexes=getapsoe(1,numberOfEquations,noe)
      for eqIndex in eqIndexes
        varGroup=getindex(nonliArgs,eqIndex)
        allVars=union(varGroup...)
        if length(allVars) == noe
          eqGroup=getindex(nonliFuns,eqIndex)
          #println("eqGroup=",eqIndex," for vars:",allVars)
          indxGroup=map(x->indexin([x...],[allVars...]),varGroup)
          opt = Opt(:GN_DIRECT_L, noe)
          lower_bounds!(opt, [1.0e-3, 1.0])
          upper_bounds!(opt, [10.0,2500])
          stopval!(opt, 1.0e-12)
          maxtime!(opt, 1.0*noe)
          #ftol_abs!(opt, 1.0e-19)
          #ftol_rel!(opt, 1.0e-18)
          min_objective!(opt, (y,gradient)->mapreduce(x->(apply(eqGroup[x],getindex(y,indxGroup[x])))^2,+,[1:noe]))
          (minf,minx,ret)=optimize(opt,ones(Float64,noe))
          #println("got $minf at $minx (returned $ret)")
          if "$ret"=="STOPVAL_REACHED"
            for j in [1:noe]
              setfield(PR,[nonliVars[eqIndex[1]]...][j],minx[j])
            end
            somthingUpdated=true
            if noe==numberOfEquations
              fullDetermined=true
            end
            break
          end
        end
      end
    end
    return somthingUpdated,fullDetermined
  end
  
  # Solve Linear System Til Something Updated But Not Full Determined
  function slstsubnfd!(danamodel::DanaModel)
    nonliArgs::Array{Set{String},1}=Array(Set{String},0)
    nonliFuns::Array{Function,1}=Array(Function,0)
    noTrys=0
    somethingUpdated=true
    fullDetermined=false
    while (somethingUpdated && !fullDetermined)
      noTrys+=1
      rVls,vars,nonliFuns,nonliArgs=solvelinear(danamodel)
      somethingUpdated,fullDetermined=update!(danamodel,rVls,vars)
    end
    return somethingUpdated,fullDetermined,nonliFuns,nonliArgs,noTrys
  end

  # Solve NonLinear Equations of One Variable One By One
  function snleoovobo!(danamodel::DanaModel,nonliFuns::Array{Function,1}=Array(Function,0),nonliArgs::Array{Set{String},1}=Array(Set{String},0))
    i=1
    noTrys=0
    somethingUpdated=false
    fullDetermined=true
    while (i<=length(nonliFuns))
      if length(nonliArgs[i])==1
        noTrys+=1
        result=fzero(nonliFuns[i],[0,typemax(Int64)])
        setfield(danamodel,[nonliArgs[i]...][1],result)
        somethingUpdated=true
      else
        fullDetermined=false
      end
      i=i+1
    end
    return somethingUpdated,fullDetermined,noTrys
  end

  #solve equations of a model
  #call solve after setEquationFlow()
  function solvelinear(danamodel::DanaModel)
    #replace variables & parameters with values
    equations=replace(danamodel)
    #call simplify on eatch equation
    sequations::Array{Expr,1}=Array(Expr,0)
    for eq in equations
      try
        seq=simplify(eq)
        if isa(seq,Expr) 
          push!(sequations,seq)
        else
          # nothing to do!
        end
      catch y
        if isa(y,DomainError)
          println ("can't simplify following equation:\n",eq);
        end
        println ("can't simplify following equation:\n",eq);
        throw(y)
      end
    end
    #equations=vals*vars (linear equations)
    vals,vars,nolinearFunctions,nolinearArgs=analysis(sequations)
    #reduced row echelon form
    rreModel=rref(vals)
    return rreModel,vars,nolinearFunctions,nolinearArgs
  end
  function rref(U::Array{Float64,2})		
    nr, nc = size(U)		
    e = eps(norm(U,Inf))		
    i = j = 1		
    while i <= nr && j <= nc		
      (m, mi) = findmax(abs(U[i:nr,j]))		
      mi = mi+i - 1		
      if m <= e		
        U[i:nr,j] = 0		
        j += 1		
      else		
        for k=j:nc		
          U[i, k], U[mi, k] = U[mi, k], U[i, k]		
        end		
        d = U[i,j]		
        for k = j:nc		
          U[i,k] /= d		
        end		
        for k = 1:nr		
          if k != i		
            d = U[k,j]		
            for l = j:nc		
              U[k,l] -= d*U[i,l]		
            end		
          end		
        end		
        i += 1		
        j += 1		
      end		
    end		
    U		
  end		
  rref(x::Number) = one(x)
  
  #generate indexes for all possible system of _noe equations[APSOE]. 
  #where equations are selected from _minIndex to _maxIndex of a list of equations
  function getapsoe(minIndex::Int,maxIndex::Int,noe::Int)
    if 1<noe
      jj::Vector=Vector[]
      for k in [minIndex+1:maxIndex] 
        j=getAPSOE(k,maxIndex,noe-1)
        jj=append!(jj,[push!(e,k-1) for e in j])
      end
      return jj
    else
      return [[i] for i in minIndex:maxIndex]
    end
  end
end

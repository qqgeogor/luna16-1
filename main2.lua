require "nn"
require "cunn"
require "cutorch"
require "optim"
require "torch"
require "xlua"
require "gnuplot"
require "csvigo"
threads = require "threads"
dofile("binaryAccuracy.lua")
dofile("binaryConfusionMatrix.lua")
dofile("movingAverage.lua")
models = require "models"
shuffle = require "shuffle"
Threads = require 'threads'
Threads.serialization('threads.sharedserialize')

------------------------------------------ GLobal vars/params -------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text()
cmd:text('Options')
cmd:option('-lr',0.000005,'Learning rate')
cmd:option('-lrW',1.15,'Learning rate decay')
cmd:option('-momentum',0.96,'Momentum')
cmd:option('-batchSize',1,'batchSize')
cmd:option('-cuda',1,'CUDA')
cmd:option('-sliceSize',36,"Length size of cube around nodule")
cmd:option('-angleMax',0.5,"Absolute maximum angle for rotating image")
cmd:option('-scalingFactor',0.75,'Scaling factor for image')
cmd:option('-scalingFactorVar',0.01,'Scaling factor variance for image')
cmd:option('-clipMin',-1200,'Clip image below this value to this value')
cmd:option('-clipMax',1200,'Clip image above this value to this value')
cmd:option('-cmThresh',0.8,'confusion matrix threshold')
cmd:option('-rocInterval',0.02,'confusion matrix roc rocInterval for smooth plots')
cmd:option('-nThreads',6,"How many threads to load/preprocess data with?") 
cmd:option('-display',0,"Display images/plots") 
cmd:option('-displayFreq',90,"How often per iteration do we display an image? ") 
cmd:option('-ma',40,"Moving average paramter for graph") 
cmd:option('-activations',0,"Show activations -- needs -display 1") 
cmd:option('-log',0,"Make log file in /Results/") 
cmd:option('-run',0,'Run neral net straight away (either train or test)')
cmd:option('-test',0,"Test on 50/50 class distribution") 
cmd:option('-fullTest',0,"Full test regarding the luna16 competition - i.e. imbalanced test set") 
cmd:option('-iterations',30000,"Number of examples to use.") 
cmd:option('-loadModel',0,"Load model") 
cmd:option('-para',3,"Are we using a parallel network? If bigger than 0 then this is equal to number of inputs. Otherwise input number is 1.") 
--cmd:option('-nInputScalingFactors',3,"Number of input scaling factors.") 
-- K fold cv options
cmd:option('-kFold',1,"Are we doing k fold?") 
cmd:option('-fold',40,"Which fold to train on. 04 and 59 mean folds 0-4 and 5-9 respectivly for 2 fold.") 
cmd:text()
params = cmd:parse(arg)
params.model = model
params.rundir = cmd:string('results', params, {dir=true})

-------------------------------------------- Model ---------------------------------------------------------
modelPath = "CSVFILES/subset"..params.fold.."/para18.model"..params.fold
if params.loadModel == 1 then 
	print("==> Loading model weights ")
	model = torch.load(modelPath)
else 
	print("==> New model")
	model = models.parallelNetwork()
end
print("Model == >",model)
print("Model path ==>" ,modelPath)
print("==> Parameters",params)

-------------------------------------------- Criterion & Activations
------------------------------------------
--criterion = nn.MSECriterion()
criterion = nn.BCECriterion()

if params.log == 1 then  -- Log file local logPath = "results/"..params.rundir
	paths.mkdir(logPath) logger = optim.Logger(logPath.. '/results.log')
end

--Show activations need first n layers
if params.activations == 1 then modelActivations1 = nn.Sequential() for i=1,3
	do modelActivations1:add(model:get(i)) end end

-------------------------------------------- Optimization --------------------------------------------------
optimState = {
	learningRate = params.lr,
	beta1 = 0.9,
	beta2 = 0.999,
	epsilon = 1e-8
}
optimMethod = optim.adam

if params.cuda == 1 then
	model = model:cuda()
	criterion = criterion:cuda()
	print("==> Placed on GPU")
end
-------------------------------------------- Parallel Table parameters -------------------------------------------

if params.para > 0 then
	params.sliceSize = {42,42,42}
	params.scalingFactor = {0.40,0.8,2}
	params.scalingFactorVar = {0.1,0.01,0.001}
	params.angleMax = {0.9,0.9,0.0001}
	print("==> Slices ")
	print(params.sliceSize)
	print("==> Scaling factors ")
	print(params.scalingFactor)
	print("==> Scaling factor variances ")
	print(params.scalingFactorVar)
	print("==> Max rotation angles ")
	print(params.angleMax)
end
-------------------------------------------- Misc Init ---------------------------------------------------

cm = BinaryConfusionMatrix.new(params.cmThresh,params.rocInterval)
ma = MovingAverage.new(params.ma)

-------------------------------------------- Loading data with threads ---------------------------------------------------


print(string.format("==> Using %d threads ",params.nThreads))
do
	local options = params -- make an upvalue to serialize over to donkey threads
	donkeys = Threads(
		params.nThreads,
		function()
			require 'torch'
		end,
		function(idx)
			tid = idx
			if options.test == 1 then 
				local seed = idx
				torch.manualSeed(seed)
				print(string.format('Initializing test thread with id: %d seed: %d', tid, seed))
			else 	
				print(string.format('Initializing training thread with id: %d ', tid))
			end
			params = options -- pass to all donkeys via upvalue
			params.tid = tid -- pass thread id as a paramter
			loadData = require "loadData"
			loadData.Init()
			print("==> Initialized.")
		end
		)
end
function displayImageInit()
	if displayTrue==nil and params.display==1 then
		print("Initializing displays ==>")
		init = torch.range(1,torch.pow(512,2),1):reshape(512,512)
		local zoom = 0.7
		--init = image.lena()
		imgZ = image.display{image=init, zoom=zoom, offscreen=false}
		imgY = image.display{image=init, zoom=zoom, offscreen=false}
		imgX = image.display{image=init, zoom=zoom, offscreen=false}
		--[[
		imgZ1 = image.display{image=init, zoom=zoom, offscreen=false}
		imgY1 = image.display{image=init, zoom=zoom, offscreen=false}
		imgX1 = image.display{image=init, zoom=zoom, offscreen=false}
		imgZ2 = image.display{image=init, zoom=zoom, offscreen=false}
		imgY2 = image.display{image=init, zoom=zoom, offscreen=false}
		imgX2 = image.display{image=init, zoom=zoom, offscreen=false}
		]]--
		if params.activations == 1 then
			activationDisplay1 = image.display{image=init, zoom=zoom, offscreen=false}
			--activationDisplay2 = image.display{image=init, zoom=zoom, offscreen=false}
		end
		displayTrue = "not nil"
	end
end
function displayImage(inputs,targets,predictions,idx)
		local class = "Class = " .. targets[1][1] .. ". Prediction = ".. predictions[1]
		-- Display rotated images
		-- Middle Slice
		image.display{image = inputs[1][1][{{idx},{},{params.sliceSize[1]/2 +1}}]:reshape(params.sliceSize[1],params.sliceSize[1]), win = imgZ, legend = class}
		image.display{image = inputs[1][2][{{idx},{},{params.sliceSize[2]/2 +1}}]:reshape(params.sliceSize[2],params.sliceSize[2]), win = imgY, legend = class}
		image.display{image = inputs[1][3][{{idx},{},{params.sliceSize[3]/2 +1}}]:reshape(params.sliceSize[3],params.sliceSize[3]), win = imgX, legend = class}

		-- Slice + 1
		--[[
		image.display{image = inputs[{{idx},{},{params.sliceSize/2 +2}}]:reshape(params.sliceSize,params.sliceSize), win = imgZ1, legend = class}
		image.display{image = inputs[{{idx},{},{},{params.sliceSize/2 +2}}]:reshape(params.sliceSize,params.sliceSize), win = imgY1, legend = class}
		image.display{image = inputs[{{idx},{},{},{},{params.sliceSize/2 +2}}]:reshape(params.sliceSize,params.sliceSize), win = imgX1, legend = class}
		-- Slice + 2 
		image.display{image = inputs[{{idx},{},{params.sliceSize/2 }}]:reshape(params.sliceSize,params.sliceSize), win = imgZ2, legend = class}
		image.display{image = inputs[{{idx},{},{},{params.sliceSize/2 }}]:reshape(params.sliceSize,params.sliceSize), win = imgY2, legend = class}
		image.display{image = inputs[{{idx},{},{},{},{params.sliceSize/2 }}]:reshape(params.sliceSize,params.sliceSize), win = imgX2, legend = class}
		]]--

		-- Display first layer activtion plane. Draw one activation plane at random and slice on first (z) dimension.
		if params.activations == 1 then 
			local activations1 = modelActivations1:forward(inputs)
			local randomFeat1 = torch.random(1,modelActivations1:get(2).nOutputPlane)
			image.display{image = activations1[{{1},{randomFeat1},{params.sliceSize/2}}]:reshape(params.sliceSize,params.sliceSize), win = activationDisplay1, legend = "Activations"}
		end
end

function train(inputs,targets)
	if i == nil then 
		print("==> Initalizing training")
		i = 1 
		epochLosses = {}
		batchLosses = {}
		batchLossesMA = {}
		accuraccies = {}
		if model then parameters,gradParameters = model:getParameters() end
		lrChangeThresh = 0.7
		timer = torch.Timer()
	end
	
	if params.cuda == 1 then
		targets = targets:cuda()
	end
		
	function feval(x)
		if x~= parameters then parameters:copy(x) end
		gradParameters:zero()
		predictions = model:forward(inputs[1])
		loss = criterion:forward(predictions,targets)
		cm:add(predictions[1],targets[1][1])
		dLoss_d0 = criterion:backward(predictions,targets)
		if params.log == 1 then logger:add{['loss'] = loss } end
		model:backward(inputs[1], dLoss_d0)

		return loss, gradParameters

	end
	-- Possibly improve this to take batch with large error more frequently
	_, batchLoss = optimMethod(feval,parameters,optimState)

	-- Performance metrics
	accuracy = binaryAccuracy(targets,predictions,params.cuda)
	loss = criterion:forward(predictions,targets)

	accuraccies[#accuraccies + 1] = accuracy
	batchLosses[#batchLosses + 1] = loss 
	accuracciesT = torch.Tensor(accuraccies)
	batchLossesT = torch.Tensor(batchLosses)
	local t = torch.range(1,batchLossesT:size()[1])
	if i > params.ma then 
		--print(string.format("Accuracy (value) overall = %f",accuracciesT:mean()))
	end

	--Plot & Confusion Matrix
	if i % params.displayFreq == 0 and i > params.ma then
		accMa = accuracciesT[{{-params.ma,-1}}]:mean()
		print(string.format("Iteration %d accuracy= %f. MA loss of last 20 batches == > %f. MA accuracy ==> %f. Overall accuracy ==> %f ", i, accuracy, batchLossesT[{{-params.ma,-1}}]:mean(), accMa,accuracciesT:mean()))
		gnuplot.figure(1)
		--print(batchLossesT:size())
		MA = ma:forward(batchLossesT)
		MA:resize(MA:size()[1])
		t = torch.range(1,MA:size()[1])
		--gnuplot.plot({"Train loss ma ",t,MA})
		print("==> Confusion matrix")
		print(cm.cm)
		cm:performance()
		cm:roc()
		print("==> Linear weighting of sub nets")
		print(model:get(3).weight)
	end


	if i % 1000 == 0 then
		print("==> Saving weights for ".. modelPath)
		torch.save(modelPath,model)
	end

	if i % 800 == 0 then
		-- Learning rate change
		print("==> Dropping lr from ",params.lr)
		params.lr = params.lr/params.lrW
		print("==> to",params.lr)

	end
	
	displayImageInit()
	if params.display == 1 and displayTrue ~= nil and i % params.displayFreq == 0 then 
		displayImage(inputs,targets,predictions,1)
	end

	xlua.progress(i,params.iterations)
	i = i + 1
	collectgarbage()
end

function test(inputs,targets)

	if i == nil then 
		print("==> Initalizing training")
		i = 1 
		epochLosses = {}
		batchLosses = {}
		batchLossesMA = {}
		accuraccies = {}
	end

	if params.cuda == 1 then
		targets = targets:cuda()
	end

	predictions = model:forward(inputs[1])
	loss = criterion:forward(predictions,targets)
	cm:add(predictions[1],targets[1][1])


	-- Performance metrics
	accuracy = binaryAccuracy(targets,predictions,params.cuda)
	loss = criterion:forward(predictions,targets)

	accuraccies[#accuraccies + 1] = accuracy
	batchLosses[#batchLosses + 1] = loss 
	accuracciesT = torch.Tensor(accuraccies)
	batchLossesT = torch.Tensor(batchLosses)

	if i > params.ma then 
		accMa = accuracciesT[{{-params.ma,-1}}]:mean()
		--print(string.format("Iteration %d accuracy= %f. MA loss of last 20 batches == > %f. MA accuracy ==> %f. Overall accuracy ==> %f ", i, accuracy, batchLossesT[{{-ma,-1}}]:mean(), accMa,accuracciesT:mean()))



	end

	--Plot & Confusion Matrix
	if i % params.displayFreq  == 0 then
		gnuplot.figure(1)
		MA = ma:forward(batchLossesT)
		MA:resize(MA:size()[1])
		t = torch.range(1,MA:size()[1])
		--gnuplot.plot({"Test loss ma ",t,MA})
		print("==> Confusion matrix")
		print(cm.cm)
		cm:performance()
		cm:roc()
		--print("==> Linear weighting of sub nets")
		--print(model:get(3).weight)
		print(string.format("Accuracy (value) overall = %f",accuracciesT:mean()))
	end

	displayImageInit()
	if params.display == 1 and displayTrue ~= nil and i % 50 == 0 then 
		displayImage(inputs,targets,predictions,1)
	end

	xlua.progress(i,params.iterations)
	i = i + 1
	collectgarbage()
end
 
inputs = {}
targets = {}
testCsv = {}
time = torch.Timer()
testCsv[1] = {"seriesuid","coordX","coordY","coordZ","class","probability"}
threadsFinished = 0 
if params.run == 1 then 
	if params.test == 1 then params.iterations = 100 end 
	while threadsFinished < params.nThreads do 
		--print("nThreads finished = ", threadsFinished)
		donkeys:addjob(function()
					local x,y,relaventInfo,threadStatus = loadData.getBatch(C0,C1,params.batchSize,params.sliceSize,params.clipMin,
					params.clipMax,params.angleMax,params.scalingFactor,params.scalingFactorVar,
					params.test,params.para,params.fullTest)
					--print("LOCAL thread ",params.tid, " has threadstatus ", threadStatus)
					return x,y,relaventInfo,threadStatus, params.tid
				end,
				function(x,y,relaventInfo,threadStatus,tid)

					--print("GLOBAL thread ",tid, " has threadstatus ", threadStatus)
					if params.test == 1 or params.fullTest == 1 then
						if threadStatus == 0 then
							test(x,y)
							relaventInfo[#relaventInfo + 1] = predictions[1]
							--relaventInfo[#relaventInfo + 1] = tid
							testCsv[#testCsv + 1] = relaventInfo
						elseif threadStatus == 1 then
							print(tid, " has finished.***********")
							threadsFinished = threadsFinished + 1
						end

						--print("Threads finished  = ",  threadsFinished)
					else 
						train(x,y)
					end
				end
				)
	end
	donkeys:synchronize()
end

if params.fullTest ==1 then
	print("==> Writing test submission")
	csvigo.save("CSVFILES/subset"..params.fold.."/testSubmission"..params.fold..".csv",testCsv)
end










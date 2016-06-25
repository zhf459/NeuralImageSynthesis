require 'torch'
require 'nn'

-- Define an nn Module to compute content loss in-place
local MSE, parent = torch.class('nn.MSE', 'nn.Module')

function MSE:__init(targets, weights)
    parent.__init(self)
    self.targets = targets
    self.weights = weights
    self.loss = 0
    self.crit = nn.MSECriterion()
end

function MSE:updateOutput(input)
    self.loss = 0
    if input:nElement() == self.targets[{{1},{},{},{}}]:nElement() then
        for t = 1, self.targets:size()[1] do
            self.loss = self.loss + self.weights[t] * self.crit:forward(input, self.targets[t])
        end
    else
        print('WARNING: Skipping content loss')
    end
    self.output = input
    return self.output
end

function MSE:updateGradInput(input, gradOutput)
    self.gradInput = input.new(#input):fill(0)
    if input:nElement() == self.targets[{{1},{},{},{}}]:nElement() then
        for t = 1, self.targets:size()[1] do
            self.gradInput = self.gradInput + self.crit:backward(input, self.targets[t]):mul(self.weights[t])
        end
    end
    self.gradInput:add(gradOutput)
    return self.gradInput
end

-- Returns a network that computes the CxC Gram matrix from inputs
-- of size C x H x W
function GramMatrix()
    local net = nn.Sequential()
    net:add(nn.View(-1):setNumInputDims(2))
    local concat = nn.ConcatTable()
    concat:add(nn.Identity())
    concat:add(nn.Identity())
    net:add(concat)
    net:add(nn.MM(false, true))
    return net
end

-- Define an nn Module to compute style loss in-place
local GramMSE, parent = torch.class('nn.GramMSE', 'nn.Module')

function GramMSE:__init(targets, weights)
    parent.__init(self)
    self.targets = targets
    self.weights = weights
    self.loss = 0
    self.gram = GramMatrix()
    self.G = nil
    self.crit = nn.MSECriterion()
end

function GramMSE:updateOutput(input)
    self.G = self.gram:forward(input)
    self.G:div(input[{{1},{},{}}]:nElement())
    self.loss = 0
    for t = 1, self.targets:size()[1] do
        self.loss = self.loss + self.weights[t] * self.crit:forward(self.G, self.targets[t])
    end
    self.output = input
    return self.output
end

function GramMSE:updateGradInput(input, gradOutput)
    self.gradInput = input.new(#input):fill(0)
    for t = 1, self.targets:size()[1] do
        local dG = self.crit:backward(self.G, self.targets[t])
        dG:div(input[{{1},{},{}}]:nElement())
        self.gradInput = self.gradInput + self.gram:backward(input, dG):mul(self.weights[t])
    end
    self.gradInput:add(gradOutput)
    return self.gradInput
end

-- returns layer that computes linear transform in channel dimension
function LinTrans(linear_transform)
    local shape = linear_transform:size()
    local lintrans = nn.SpatialConvolution(shape[2], shape[1], 1, 1, 1, 1, 0, 0)
    lintrans.bias:zero()
    lintrans.weight = linear_transform:typeAs(lintrans.weight)
    return lintrans
end

-- Define an nn Module to compute content loss in-place with linear transform
local LinTransMSE, parent = torch.class('nn.LinTransMSE', 'nn.Module')

function LinTransMSE:__init(targets, weights, linear_transform)
    parent.__init(self)
    self.targets = targets
    self.weights = weights
    self.loss = 0
    self.linear_transform = linear_transform 
    self.trans_input = nil
    self.crit = nn.MSECriterion()
end

function LinTransMSE:updateOutput(input)
    if input[{{1},{1},{},{}}]:nElement() == self.targets[{{1},{1},{},{}}]:nElement() then
        self.trans_input = self.linear_transform:forward(input)
        self.loss = 0
        for t = 1, self.targets:size()[1] do
            self.loss = self.loss + self.weights[t] * self.crit:forward(self.trans_input, self.targets[t])
        end
    else
        print('WARNING: Skipping content loss')
    end
    self.output = input
    return self.output
end

function LinTransMSE:updateGradInput(input, gradOutput)
    if input[{{1},{1},{},{}}]:nElement() == self.targets[{{1},{1},{},{}}]:nElement() then
        self.gradInput = input.new(#input):fill(0)
        local dtrans_input = self.crit:backward(self.trans_input, self.target)
        for t = 1, self.targets:size()[1] do
            self.gradInput = self.gradInput + self.linear_transform:backward(input, dtrans_input):mul(self.weights[t])
        end
    end
    self.gradInput:add(gradOutput)
    return self.gradInput
end

-- Define an nn Module to compute style loss in-place with linear transform
local LinTransGramMSE, parent = torch.class('nn.LinTransGramMSE', 'nn.Module')

function LinTransGramMSE:__init(targets, weights, linear_transform)
    parent.__init(self)
    self.targets = targets
    self.weights = weights
    self.linear_transform = linear_transform 
    self.trans_input = nil
    self.loss = 0
    self.gram = GramMatrix()
    self.G = nil
    self.crit = nn.MSECriterion()
end

function LinTransGramMSE:updateOutput(input)
    self.trans_input = self.linear_transform:forward(input)
    self.G = self.gram:forward(self.trans_input)
    self.G:div(self.trans_input[{{1},{},{}}]:nElement())
    self.loss = 0
    for t = 1, self.targets:size()[1] do
        self.loss = self.loss + self.weights[t] * self.crit:forward(self.G, self.targets[t])
    end
    self.output = input
    return self.output
end

function LinTransGramMSE:updateGradInput(input, gradOutput)
    self.gradInput = input.new(#input):fill(0)
    for t = 1, self.targets:size()[1] do
        local dG = self.crit:backward(self.G, self.targets[t])
        dG:div(self.trans_input[{{1},{},{}}]:nElement())
        local dtrans_input = self.gram:backward(self.trans_input, dG)
        self.gradInput = self.gradInput + self.linear_transform:backward(input, dG):mul(self.weights[t])
    end
    self.gradInput:add(gradOutput)
    return self.gradInput
end


local TVLoss, parent = torch.class('nn.TVLoss', 'nn.Module')

function TVLoss:__init(strength)
    parent.__init(self)
    self.strength = strength
    self.x_diff = torch.Tensor()
    self.y_diff = torch.Tensor()
end

function TVLoss:updateOutput(input)
    self.output = input
    return self.output
end

-- TV loss backward pass inspired by kaishengtai/neuralart
function TVLoss:updateGradInput(input, gradOutput)
    self.gradInput:resizeAs(input):zero()
    local C, H, W = input:size(1), input:size(2), input:size(3)
    self.x_diff:resize(3, H - 1, W - 1)
    self.y_diff:resize(3, H - 1, W - 1)
    self.x_diff:copy(input[{{}, {1, -2}, {1, -2}}])
    self.x_diff:add(-1, input[{{}, {1, -2}, {2, -1}}])
    self.y_diff:copy(input[{{}, {1, -2}, {1, -2}}])
    self.y_diff:add(-1, input[{{}, {2, -1}, {1, -2}}])
    self.gradInput[{{}, {1, -2}, {1, -2}}]:add(self.x_diff):add(self.y_diff)
    self.gradInput[{{}, {1, -2}, {2, -1}}]:add(-1, self.x_diff)
    self.gradInput[{{}, {2, -1}, {1, -2}}]:add(-1, self.y_diff)
    self.gradInput:mul(self.strength)
    self.gradInput:add(gradOutput)
    return self.gradInput
end

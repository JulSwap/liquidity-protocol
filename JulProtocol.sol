// SPDX-License-Identifier: MIT

pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/libraries/UniswapV2Library.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import '@uniswap/v2-periphery/contracts/interfaces/IWETH.sol';

contract JulProtocol is Ownable {
    // should be changed on mainnet deployment ///////////////////////////////////////////////////////
    uint256 constant TIME_LIMIT = 86400; //15 minutes for testing , normally 1 days                 //
    address router02Address = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;                           //
    address public UNISWAP_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;                    //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    uint256 lockedTokens; 

    IUniswapV2Router02 public uniswapRouter02;
    address private WETH;

    address TOKEN;
    IERC20 JulToken;
    
    bool release1 = false;
    bool release2 = false;
    bool release3 = false;
    bool release4 = false;

    uint256 totalEthFee;

    constructor(address token) public payable {
        TOKEN = token;
        JulToken = IERC20(token);

        uniswapRouter02 = IUniswapV2Router02(router02Address);
        WETH = uniswapRouter02.WETH();

        lockedTokens = 75000000000000000000000; 
    }

    struct UserDeposits {
        uint256 amountETH;
        uint256 lastDepositedDate;
        uint256 pendingETH;
    }

    mapping(address => UserDeposits) public protocolusers;

    function calculatePercent(uint256 _eth, uint256 _percent)
        public
        pure
        returns (uint256 interestAmt)
    {
        return (_eth * _percent) / 1000;
    }
    
    function calculateInterest(address _user) private
    {
        require(protocolusers[_user].lastDepositedDate > 0, "this is first deposite.");
        uint256 time = now - protocolusers[_user].lastDepositedDate;
        if(time >= TIME_LIMIT)
        {
            uint256 nd = time / TIME_LIMIT;
            protocolusers[_user].pendingETH = protocolusers[_user].pendingETH + calculatePercent(protocolusers[_user].amountETH, 2) * nd;
            protocolusers[_user].lastDepositedDate = now;
        }
    }

    function addEth()
        public
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        require(msg.value >= 500000000000000000, "Insufficient ethereum");

        uint256 txFee = calculatePercent(msg.value, 3);
        uint ethAmount = msg.value - txFee;

        uint reserveA;
        uint reserveB;

        (reserveA, reserveB) = UniswapV2Library.getReserves(
            UNISWAP_FACTORY,
            WETH,
            TOKEN
        );

        uint tokenAmount = UniswapV2Library.quote(ethAmount, reserveA, reserveB); 

        uint256 balance = JulToken.balanceOf(address(this));
        uint256 tokensAvail = balance - lockedTokens;
        require(tokensAvail >= tokenAmount, "Insufficient Tokens in Pool");

        address payable spender = address(this);
        totalEthFee += txFee;
        // spender.transfer(txFee);

        // IERC20 julToken = IERC20(TOKEN);
        JulToken.approve(router02Address, tokenAmount);

        (amountToken, amountETH, liquidity) = uniswapRouter02.addLiquidityETH{
            value: ethAmount
        }(TOKEN, tokenAmount, tokenAmount, 1, spender, block.timestamp);

        if(protocolusers[msg.sender].lastDepositedDate == 0) //first deposit
        {
            protocolusers[msg.sender].lastDepositedDate = now;
        }
        else
        {
            calculateInterest(msg.sender);
        }
        protocolusers[msg.sender].amountETH = protocolusers[msg.sender].amountETH + ethAmount;
    }

    function readUsersDetails(address _user)
        public
        view
        returns (
            uint256 td,
            uint256 trd,
            uint256 trwi
        )
    {
        if(protocolusers[_user].lastDepositedDate == 0)
        {
            td = 0;
            trd = 0;
            trwi = 0;
        }
        else{
            td = protocolusers[_user].amountETH;
            uint256 time = now - protocolusers[_user].lastDepositedDate;

            if(time >= TIME_LIMIT ){
                uint256 nd = time / TIME_LIMIT;
                uint256 percent = calculatePercent(
                        protocolusers[_user].amountETH,
                        2
                    ) * nd;
                trd = protocolusers[_user].pendingETH + percent;
                trwi = protocolusers[_user].amountETH + trd ;
            }
            else{
                trd = protocolusers[_user].pendingETH;
                trwi = protocolusers[_user].pendingETH;
            }
        }
        return (td, trd, trwi);
    }

    function removeETH(uint256 _amountETH)
    public payable returns(uint256 amountToken, uint256 amountETH)
    {
        (,,uint trwi) = readUsersDetails(msg.sender);

        require(trwi >= _amountETH, "Insufficient Removable Balance");
        
        address pairAddress = UniswapV2Library.pairFor(
            UNISWAP_FACTORY,
            WETH,
            TOKEN
        );
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        (uint reserveA, ) = UniswapV2Library.getReserves(
            UNISWAP_FACTORY,
            WETH,
            TOKEN
        );
        require(reserveA > 0 , "Pool have no ETH");

        uint totalSupply = pair.totalSupply();
        uint liqAmt = UniswapV2Library.quote(_amountETH, reserveA, totalSupply);
        
        uint balance = pair.balanceOf(address(this));
        require(liqAmt <= balance, "Insufficient Liquidity in Uniswap");

        pair.transfer(pairAddress, liqAmt);

        (uint amount0, uint amount1) = pair.burn(address(this));
        (address token0,) = UniswapV2Library.sortTokens(WETH, TOKEN);
        (amountETH, amountToken) = WETH == token0 ? (amount0, amount1) : (amount1, amount0);
        
        //update deposited data
        calculateInterest(msg.sender);
        if(protocolusers[msg.sender].pendingETH >= amountETH)
        {
            protocolusers[msg.sender].pendingETH = protocolusers[msg.sender].pendingETH - amountETH;
        }
        else{
            protocolusers[msg.sender].amountETH = protocolusers[msg.sender].amountETH + protocolusers[msg.sender].pendingETH - amountETH;
            protocolusers[msg.sender].pendingETH = 0;
        }
        //end

        IWETH(WETH).withdraw(amountETH);
        msg.sender.transfer(amountETH);
    }
 
    function getLiquidityBalance() public view returns (uint256 liquidity) {
        address pair = UniswapV2Library.pairFor(UNISWAP_FACTORY, WETH, TOKEN);
        liquidity = IERC20(pair).balanceOf(address(this));
    }

    function withdrawFee(address payable ca, uint256 amount) public onlyOwner{
        require(totalEthFee >= amount , "Insufficient ETH amount!");
        require(address(this).balance >= amount , "Insufficient ETH balance in contract!" );
        ca.transfer(amount);
        totalEthFee = totalEthFee - amount ;
    }

    function tokenRelease() public onlyOwner returns (bool result){
        // total protocol eth balance
        uint256 eth;
        (eth, ) = getBalanceFromUniswap();
        
        if(eth >= 6000000000000000000000 && !release1) {
            JulToken.transfer(msg.sender, 20000000000000000000000);
            lockedTokens = 55000000000000000000000;
            release1 = true;
            return true;
        } else if(eth >= 15000000000000000000000 && !release2) {
            JulToken.transfer(msg.sender, 20000000000000000000000);
            lockedTokens = 35000000000000000000000; 
            release2 = true;
            return true;            
        } else if(eth >= 30000000000000000000000 && !release3) {
            JulToken.transfer(msg.sender, 17500000000000000000000);
            lockedTokens = 17500000000000000000000; 
            release3 = true;
            return true;
        } else if(eth >= 45000000000000000000000 && !release4) {
            JulToken.transfer(msg.sender, 17500000000000000000000);
            lockedTokens = 0;
            release4 = true;
            return true;
        }

        return false;
    }

    /// @return The balance of the contract
    function protocolBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getBalanceFromUniswap()
        public
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (reserveA, reserveB) = UniswapV2Library.getReserves(
            UNISWAP_FACTORY,
            WETH,
            TOKEN
        );
    }

    receive() external payable {}

    fallback() external payable {
        // to get ether from uniswap exchanges
    }
}   
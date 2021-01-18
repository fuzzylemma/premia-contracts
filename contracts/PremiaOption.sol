// SPDX-License-Identifier: MIT

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/token/ERC1155/ERC1155.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/SafeCast.sol';

import "./interface/IFeeCalculator.sol";
import "./interface/IFlashLoanReceiver.sol";
import "./interface/IPremiaReferral.sol";
import "./interface/IPremiaUncutErc20.sol";

import "./uniswapV2/interfaces/IUniswapV2Router02.sol";


contract PremiaOption is Ownable, ERC1155, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct TokenSettings {
        uint256 strikePriceIncrement;   // Increment for strike price
        bool isDisabled;                // Whether this token is disabled or not
    }

    struct OptionWriteArgs {
        address token;                  // Token address
        uint256 amount;                 // Amount of tokens to write option for
        uint256 strikePrice;            // Strike price (Must follow strikePriceIncrement of token)
        uint256 expiration;             // Expiration timestamp of the option (Must follow expirationIncrement)
        bool isCall;                    // If true : Call option | If false : Put option
    }

    struct OptionData {
        address token;                  // Token address
        uint256 strikePrice;            // Strike price (Must follow strikePriceIncrement of token)
        uint256 expiration;             // Expiration timestamp of the option (Must follow expirationIncrement)
        bool isCall;                    // If true : Call option | If false : Put option
        uint256 claimsPreExp;           // Amount of options from which the funds have been withdrawn pre expiration
        uint256 claimsPostExp;          // Amount of options from which the funds have been withdrawn post expiration
        uint256 exercised;              // Amount of options which have been exercised
        uint256 supply;                 // Total circulating supply
    }

    struct Pool {
        uint256 tokenAmount;
        uint256 denominatorAmount;
    }

    IERC20 public denominator;

    //////////////////////////////////////////////////

    address public feeRecipient;                     // Address receiving fees

    IPremiaReferral public premiaReferral;
    IPremiaUncutErc20 public uPremia;
    IFeeCalculator public feeCalculator;

    //////////////////////////////////////////////////

    address[] public tokens;
    mapping (address => TokenSettings) public tokenSettings;

    //////////////////////////////////////////////////

    uint256 public nextOptionId = 1;

    // Offset to add to Unix timestamp to make it Fri 23:59:59 UTC
    uint256 private constant _baseExpiration = 172799;
    // Expiration increment
    uint256 private constant _expirationIncrement = 1 weeks;
    // Max expiration time from now
    uint256 public maxExpiration = 365 days;

    // Uniswap routers allowed to be used for swap from flashExercise
    address[] public whitelistedUniswapRouters;

    // token => expiration => strikePrice => isCall (1 for call, 0 for put) => optionId
    mapping (address => mapping(uint256 => mapping(uint256 => mapping (bool => uint256)))) public options;

    // optionId => OptionData
    mapping (uint256 => OptionData) public optionData;

    // optionId => Pool
    mapping (uint256 => Pool) public pools;

    // account => optionId => amount of options written
    mapping (address => mapping (uint256 => uint256)) public nbWritten;

    ////////////
    // Events //
    ////////////

    event SetToken(address indexed token, uint256 indexed strikePriceIncrement, bool indexed isDisabled);
    event OptionIdCreated(uint256 indexed optionId, address indexed token);
    event OptionWritten(address indexed owner, uint256 indexed optionId, address indexed token, uint256 amount);
    event OptionCancelled(address indexed owner, uint256 indexed optionId, address indexed token, uint256 amount);
    event OptionExercised(address indexed user, uint256 indexed optionId, address indexed token, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed optionId, address indexed token, uint256 amount);

    //////////////////////////////////////////////////
    //////////////////////////////////////////////////
    //////////////////////////////////////////////////

    constructor(string memory _uri, IERC20 _denominator, IPremiaUncutErc20 _uPremia, IFeeCalculator _feeCalculator,
        IPremiaReferral _premiaReferral, address _feeRecipient) ERC1155(_uri) {
        denominator = _denominator;
        uPremia = _uPremia;
        feeCalculator = _feeCalculator;
        feeRecipient = _feeRecipient;
        premiaReferral = _premiaReferral;
    }

    //////////////////////////////////////////////////
    //////////////////////////////////////////////////
    //////////////////////////////////////////////////

    ///////////////
    // Modifiers //
    ///////////////

    modifier notExpired(uint256 _optionId) {
        require(block.timestamp < optionData[_optionId].expiration, "Expired");
        _;
    }

    modifier expired(uint256 _optionId) {
        require(block.timestamp >= optionData[_optionId].expiration, "Not expired");
        _;
    }

    //////////
    // View //
    //////////

    function getOptionId(address _token, uint256 _expiration, uint256 _strikePrice, bool _isCall) public view returns(uint256) {
        return options[_token][_expiration][_strikePrice][_isCall];
    }

    function tokensLength() external view returns(uint256) {
        return tokens.length;
    }

    //////////////////////////////////////////////////
    //////////////////////////////////////////////////
    //////////////////////////////////////////////////

    ///////////
    // Admin //
    ///////////

    function setURI(string memory newuri) external onlyOwner {
        _setURI(newuri);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function setMaxExpiration(uint256 _max) external onlyOwner {
        maxExpiration = _max;
    }

    function setPremiaReferral(IPremiaReferral _premiaReferral) external onlyOwner {
        premiaReferral = _premiaReferral;
    }

    function setPremiaUncutErc20(IPremiaUncutErc20 _uPremia) external onlyOwner {
        uPremia = _uPremia;
    }

    function setFeeCalculator(IFeeCalculator _feeCalculator) external onlyOwner {
        feeCalculator = _feeCalculator;
    }

    // Set settings for a token to support writing of options paired to denominator
    function setToken(address _token, uint256 _strikePriceIncrement, bool _isDisabled) external onlyOwner {
        if (!_isInArray(_token, tokens)) {
            tokens.push(_token);
        }

        require(_isDisabled || _strikePriceIncrement > 0, "Strike <= 0");
        require(_token != address(denominator), "Cant add denominator");

        tokenSettings[_token] = TokenSettings({
            strikePriceIncrement: _strikePriceIncrement,
            isDisabled: _isDisabled
        });

        emit SetToken(_token, _strikePriceIncrement, _isDisabled);
    }

    function setWhitelistedUniswapRouters(address[] memory _addrList) external onlyOwner {
        delete whitelistedUniswapRouters;

        for (uint256 i=0; i < _addrList.length; i++) {
            whitelistedUniswapRouters.push(_addrList[i]);
        }
    }

    ////////

    function getOptionIdOrCreate(address _token, uint256 _expiration, uint256 _strikePrice, bool _isCall) public returns(uint256) {
        _preCheckOptionIdCreate(_token, _strikePrice, _expiration);

        uint256 optionId = getOptionId(_token, _expiration, _strikePrice, _isCall);
        if (optionId == 0) {
            optionId = nextOptionId;
            options[_token][_expiration][_strikePrice][_isCall] = optionId;

            pools[optionId] = Pool({ tokenAmount: 0, denominatorAmount: 0 });
            optionData[optionId] = OptionData({
            token: _token,
            expiration: _expiration,
            strikePrice: _strikePrice,
            isCall: _isCall,
            claimsPreExp: 0,
            claimsPostExp: 0,
            exercised: 0,
            supply: 0
            });

            emit OptionIdCreated(optionId, _token);

            nextOptionId = nextOptionId.add(1);
        }

        return optionId;
    }

    //

    function writeOptionFrom(address _from, OptionWriteArgs memory _option, address _referrer) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _writeOption(_from, _option, _referrer);
    }

    function writeOption(OptionWriteArgs memory _option, address _referrer) public {
        _writeOption(msg.sender, _option, _referrer);
    }

    function _writeOption(address _from, OptionWriteArgs memory _option, address _referrer) internal nonReentrant {
        require(_option.amount > 0, "Amount <= 0");

        uint256 optionId = getOptionIdOrCreate(_option.token, _option.expiration, _option.strikePrice, _option.isCall);

        // Set referrer or get current if one already exists
        _referrer = _trySetReferrer(_from, _referrer);

        if (_option.isCall) {
            IERC20(_option.token).safeTransferFrom(_from, address(this), _option.amount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), _option.amount, IFeeCalculator.FeeType.Write);
            _payFees(_from, IERC20(_option.token), _referrer, fee, feeReferrer);

            pools[optionId].tokenAmount = pools[optionId].tokenAmount.add(_option.amount);
        } else {
            uint256 amount = _option.amount.mul(_option.strikePrice).div(1e18);
            denominator.safeTransferFrom(_from, address(this), amount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), amount, IFeeCalculator.FeeType.Write);
            _payFees(_from, denominator, _referrer, fee, feeReferrer);

            pools[optionId].denominatorAmount = pools[optionId].denominatorAmount.add(amount);
        }

        nbWritten[_from][optionId] = nbWritten[_from][optionId].add(_option.amount);

        mint(_from, optionId, _option.amount);

        emit OptionWritten(_from, optionId, _option.token, _option.amount);
    }

    //

    function cancelOptionFrom(address _from, uint256 _optionId, uint256 _amount) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _cancelOption(_from, _optionId, _amount);
    }

    function cancelOption(uint256 _optionId, uint256 _amount) public {
        _cancelOption(msg.sender, _optionId, _amount);
    }

    // Cancel an option before expiration, by burning the NFT for withdrawal of deposit (Can only be called by writer of the option)
    // Must be called before expiration (Expiration check is done in burn function call)
    function _cancelOption(address _from, uint256 _optionId, uint256 _amount) internal nonReentrant {
        require(_amount > 0, "Amount <= 0");
        require(nbWritten[_from][_optionId] >= _amount, "Not enough written");

        burn(_from, _optionId, _amount);
        nbWritten[_from][_optionId] = nbWritten[_from][_optionId].sub(_amount);

        if (optionData[_optionId].isCall) {
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.sub(_amount);
            IERC20(optionData[_optionId].token).safeTransfer(_from, _amount);
        } else {
            uint256 amount = _amount.mul(optionData[_optionId].strikePrice).div(1e18);
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.sub(amount);
            denominator.safeTransfer(_from, amount);
        }

        emit OptionCancelled(_from, _optionId, optionData[_optionId].token, _amount);
    }

    //

    function exerciseOptionFrom(address _from, uint256 _optionId, uint256 _amount, address _referrer) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _exerciseOption(_from, _optionId, _amount, _referrer);
    }

    function exerciseOption(uint256 _optionId, uint256 _amount, address _referrer) public {
        _exerciseOption(msg.sender, _optionId, _amount, _referrer);
    }

    function _exerciseOption(address _from, uint256 _optionId, uint256 _amount, address _referrer) internal nonReentrant {
        require(_amount > 0, "Amount <= 0");

        OptionData storage data = optionData[_optionId];

        burn(_from, _optionId, _amount);
        data.exercised = uint256(data.exercised).add(_amount);

        IERC20 tokenErc20 = IERC20(data.token);

        uint256 tokenAmount = _amount;
        uint256 denominatorAmount = _amount.mul(data.strikePrice).div(1e18);

        // Set referrer or get current if one already exists
        _referrer = _trySetReferrer(_from, _referrer);

        if (data.isCall) {
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.sub(tokenAmount);
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.add(denominatorAmount);

            denominator.safeTransferFrom(_from, address(this), denominatorAmount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), denominatorAmount, IFeeCalculator.FeeType.Exercise);
            _payFees(_from, denominator, _referrer, fee, feeReferrer);

            tokenErc20.safeTransfer(_from, tokenAmount);
        } else {
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.sub(denominatorAmount);
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.add(tokenAmount);

            tokenErc20.safeTransferFrom(_from, address(this), tokenAmount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), tokenAmount, IFeeCalculator.FeeType.Exercise);
            _payFees(_from, tokenErc20, _referrer, fee, feeReferrer);

            denominator.safeTransfer(_from, denominatorAmount);
        }

        emit OptionExercised(_from, _optionId, data.token, _amount);
    }

    //

    function withdrawFrom(address _from, uint256 _optionId) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _withdraw(_from, _optionId);
    }

    function withdraw(uint256 _optionId) public {
        _withdraw(msg.sender, _optionId);
    }

    // Withdraw funds from an expired option (Only callable by writers with unclaimed options)
    // Funds are allocated pro-rate to writers.
    // Ex : If there is 10 ETH and 6000 denominator, a user who got 10% of options unclaimed will get 1 ETH and 600 denominator
    function _withdraw(address _from, uint256 _optionId) internal nonReentrant expired(_optionId) {
        require(nbWritten[_from][_optionId] > 0, "No option to claim");

        OptionData storage data = optionData[_optionId];

        uint256 nbTotal = uint256(data.supply).add(data.exercised).sub(data.claimsPreExp);

        // Amount of options user still has to claim funds from
        uint256 claimsUser = nbWritten[_from][_optionId];

        //

        uint256 denominatorAmount = pools[_optionId].denominatorAmount.mul(claimsUser).div(nbTotal);
        uint256 tokenAmount = pools[_optionId].tokenAmount.mul(claimsUser).div(nbTotal);

        //

        pools[_optionId].denominatorAmount.sub(denominatorAmount);
        pools[_optionId].tokenAmount.sub(tokenAmount);
        data.claimsPostExp = uint256(data.claimsPostExp).add(claimsUser);
        delete nbWritten[_from][_optionId];

        denominator.safeTransfer(_from, denominatorAmount);
        IERC20(optionData[_optionId].token).safeTransfer(_from, tokenAmount);

        emit Withdraw(_from, _optionId, data.token, claimsUser);
    }

    //

    function withdrawPreExpirationFrom(address _from, uint256 _optionId, uint256 _amount) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _withdrawPreExpiration(_from, _optionId, _amount);
    }

    function withdrawPreExpiration(uint256 _optionId, uint256 _amount) public {
        _withdrawPreExpiration(msg.sender, _optionId, _amount);
    }

    // Withdraw funds from exercised unexpired option (Only callable by writers with unclaimed options)
    function _withdrawPreExpiration(address _from, uint256 _optionId, uint256 _amount) internal nonReentrant notExpired(_optionId) {
        require(_amount > 0, "Amount <= 0");

        // Amount of options user still has to claim funds from
        uint256 claimsUser = nbWritten[_from][_optionId];
        require(claimsUser >= _amount, "Not enough claims");

        OptionData storage data = optionData[_optionId];

        uint256 nbClaimable = uint256(data.exercised).sub(data.claimsPreExp);
        require(nbClaimable >= _amount, "Not enough claimable");

        //

        nbWritten[_from][_optionId] = nbWritten[_from][_optionId].sub(_amount);
        data.claimsPreExp = uint256(data.claimsPreExp).add(_amount);

        if (data.isCall) {
            uint256 amount = _amount.mul(data.strikePrice).div(1e18);
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.sub(amount);
            denominator.safeTransfer(_from, amount);
        } else {
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.sub(_amount);
            IERC20(data.token).safeTransfer(_from, _amount);
        }
    }

    //

    function flashExerciseOptionFrom(address _from, uint256 _optionId, uint256 _amount, address _referrer, IUniswapV2Router02 _router, uint256 _amountInMax) external {
        require(isApprovedForAll(_from, msg.sender), "Not approved");
        _flashExerciseOption(_from, _optionId, _amount, _referrer, _router, _amountInMax);
    }

    function flashExerciseOption(uint256 _optionId, uint256 _amount, address _referrer, IUniswapV2Router02 _router, uint256 _amountInMax) external {
        _flashExerciseOption(msg.sender, _optionId, _amount, _referrer, _router, _amountInMax);
    }

    function _flashExerciseOption(address _from, uint256 _optionId, uint256 _amount, address _referrer, IUniswapV2Router02 _router, uint256 _amountInMax) internal nonReentrant {
        require(_amount > 0, "Amount <= 0");

        burn(_from, _optionId, _amount);
        optionData[_optionId].exercised = uint256(optionData[_optionId].exercised).add(_amount);

        IERC20 tokenErc20 = IERC20(optionData[_optionId].token);

        uint256 tokenAmount = _amount;
        uint256 denominatorAmount = _amount.mul(optionData[_optionId].strikePrice).div(1e18);

        uint256 tokenAmountRequired = tokenErc20.balanceOf(address(this));
        uint256 denominatorAmountRequired = denominator.balanceOf(address(this));

        // Set referrer or get current if one already exists
        _referrer = _trySetReferrer(_from, _referrer);

        if (optionData[_optionId].isCall) {
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.sub(tokenAmount);
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.add(denominatorAmount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), denominatorAmount, IFeeCalculator.FeeType.Exercise);

            if (tokenAmount < _amountInMax) {
                _amountInMax = tokenAmount;
            }

            // Swap enough denominator to tokenErc20 to pay fee + strike price
            uint256 tokenAmountUsed = _swap(_router, address(tokenErc20), address(denominator), denominatorAmount.add(fee).add(feeReferrer), _amountInMax)[0];

            // Pay fees
            _payFees(address(this), denominator, _referrer, fee, feeReferrer);

            uint256 profit = tokenAmount.sub(tokenAmountUsed);

            // Send profit to sender
            tokenErc20.safeTransfer(_from, profit);

            denominatorAmountRequired = denominatorAmountRequired.add(denominatorAmount);
            tokenAmountRequired = tokenAmountRequired.sub(tokenAmount);
        } else {
            pools[_optionId].denominatorAmount = pools[_optionId].denominatorAmount.sub(denominatorAmount);
            pools[_optionId].tokenAmount = pools[_optionId].tokenAmount.add(tokenAmount);

            (uint256 fee, uint256 feeReferrer) = feeCalculator.getFeeAmounts(_from, _referrer != address(0), tokenAmount, IFeeCalculator.FeeType.Exercise);

            if (denominatorAmount < _amountInMax) {
                _amountInMax = denominatorAmount;
            }

            // Swap enough denominator to tokenErc20 to pay fee + strike price
            uint256 denominatorAmountUsed =  _swap(_router, address(denominator), address(tokenErc20), tokenAmount.add(fee).add(feeReferrer), _amountInMax)[0];

            _payFees(address(this), tokenErc20, _referrer, fee, feeReferrer);

            uint256 profit = denominatorAmount.sub(denominatorAmountUsed);

            // Send profit to sender
            denominator.safeTransfer(_from, profit);

            denominatorAmountRequired = denominatorAmountRequired.sub(denominatorAmount);
            tokenAmountRequired = tokenAmountRequired.add(tokenAmount);
        }

        require(denominator.balanceOf(address(this)) >= denominatorAmountRequired, "Wrong denom bal");
        require(tokenErc20.balanceOf(address(this)) >= tokenAmountRequired, "Wrong token bal");

        emit OptionExercised(_from, _optionId, optionData[_optionId].token, _amount);
    }

    //

    function flashLoan(address _tokenAddress, uint256 _amount, IFlashLoanReceiver _receiver) public nonReentrant {
        IERC20 _token = IERC20(_tokenAddress);
        uint256 startBalance = _token.balanceOf(address(this));
        _token.safeTransfer(address(_receiver), _amount);

        (uint256 fee,) = feeCalculator.getFeeAmounts(msg.sender, false, _amount, IFeeCalculator.FeeType.FlashLoan);

        _receiver.execute(_tokenAddress, _amount, _amount.add(fee));

        uint256 endBalance = _token.balanceOf(address(this));

        uint256 endBalanceRequired = startBalance.add(fee);

        require(endBalance >= endBalanceRequired, "Failed to pay back");
        _token.safeTransfer(feeRecipient, endBalance.sub(startBalance));

        endBalance = _token.balanceOf(address(this));
        require(endBalance >= startBalance, "Failed to pay back");
    }

    /////////////////////
    // Batch functions //
    /////////////////////

    function batchWriteOption(OptionWriteArgs[] memory _options, address _referrer) external {
        for (uint256 i = 0; i < _options.length; ++i) {
            writeOption(_options[i], _referrer);
        }
    }

    function batchCancelOption(uint256[] memory _optionId, uint256[] memory _amounts) external {
        require(_optionId.length == _amounts.length, "Arrays diff len");

        for (uint256 i = 0; i < _optionId.length; ++i) {
            cancelOption(_optionId[i], _amounts[i]);
        }
    }

    function batchWithdraw(uint256[] memory _optionId) external {
        for (uint256 i = 0; i < _optionId.length; ++i) {
            withdraw(_optionId[i]);
        }
    }

    function batchExerciseOption(uint256[] memory _optionId, uint256[] memory _amounts, address _referrer) external {
        require(_optionId.length == _amounts.length, "Arrays diff len");

        for (uint256 i = 0; i < _optionId.length; ++i) {
            exerciseOption(_optionId[i], _amounts[i], _referrer);
        }
    }

    function batchWithdrawPreExpiration(uint256[] memory _optionId, uint256[] memory _amounts) external {
        require(_optionId.length == _amounts.length, "Arrays diff len");

        for (uint256 i = 0; i < _optionId.length; ++i) {
            withdrawPreExpiration(_optionId[i], _amounts[i]);
        }
    }

    //////////////////////////////////////////////////
    //////////////////////////////////////////////////
    //////////////////////////////////////////////////

    //////////////
    // Internal //
    //////////////

    function mint(address _account, uint256 _id, uint256 _amount) internal notExpired(_id) {
        OptionData storage data = optionData[_id];

        _mint(_account, _id, _amount, "");
        data.supply = uint256(data.supply).add(_amount);
    }

    function burn(address _account, uint256 _id, uint256 _amount) internal notExpired(_id) {
        OptionData storage data = optionData[_id];

        data.supply = uint256(data.supply).sub(_amount);
        _burn(_account, _id, _amount);
    }

    // Utility function to check if a value is inside an array
    function _isInArray(address _value, address[] memory _array) internal pure returns(bool) {
        uint256 length = _array.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_array[i] == _value) {
                return true;
            }
        }

        return false;
    }

    function _preCheckOptionIdCreate(address _token, uint256 _strikePrice, uint256 _expiration) internal view {
        require(!tokenSettings[_token].isDisabled, "Token disabled");
        require(tokenSettings[_token].strikePriceIncrement != 0, "Token not supported");
        require(_strikePrice > 0, "Strike <= 0");
        require(_strikePrice % tokenSettings[_token].strikePriceIncrement == 0, "Wrong strike incr");
        require(_expiration > block.timestamp, "Exp passed");
        require(_expiration.sub(block.timestamp) <= maxExpiration, "Exp > 1 yr");
        require(_expiration % _expirationIncrement == _baseExpiration, "Wrong exp incr");
    }

    function _payFees(address _from, IERC20 _token, address _referrer, uint256 _fee, uint256 _feeReferrer) internal {
        if (_fee > 0) {
            // For flash exercise
            if (_from == address(this)) {
                _token.safeTransfer(feeRecipient, _fee);
            } else {
                _token.safeTransferFrom(_from, feeRecipient, _fee);
            }

        }

        if (_feeReferrer > 0) {
            // For flash exercise
            if (_from == address(this)) {
                _token.safeTransfer(_referrer, _feeReferrer);
            } else {
                _token.safeTransferFrom(_from, _referrer, _feeReferrer);
            }
        }

        // If uPremia rewards are enabled
        if (address(uPremia) != address(0)) {
            uint256 totalFee = _fee.add(_feeReferrer);
            if (totalFee > 0) {
                uPremia.mintReward(_from, address(_token), totalFee);
            }
        }
    }

    // Try to set given referrer, returns current referrer if one already exists
    function _trySetReferrer(address _user, address _referrer) internal returns(address) {
        if (address(premiaReferral) != address(0)) {
            _referrer = premiaReferral.trySetReferrer(_user, _referrer);
        } else {
            _referrer = address(0);
        }

        return _referrer;
    }

    function _swap(IUniswapV2Router02 _router, address _from, address _to, uint256 _amount, uint256 _amountInMax) internal returns (uint256[] memory) {
        require(_isInArray(address(_router), whitelistedUniswapRouters), "Router not whitelisted");

        IERC20(_from).approve(address(_router), _amountInMax);

        address[] memory path;
        address weth = _router.WETH();

        if (_from == weth || _to == weth) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            path = new address[](3);
            path[0] = _from;
            path[1] = weth;
            path[2] = _to;
        }

        uint256[] memory amounts = _router.swapTokensForExactTokens(
            _amount,
            _amountInMax,
            path,
            address(this),
            block.timestamp.add(60)
        );

        IERC20(_from).approve(address(_router), 0);

        return amounts;
    }
}
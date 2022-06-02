//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


interface UniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface ERC20 {
    function transfer(address to, uint256 value) external returns (bool);

    function balanceOf(address owner) external view returns (uint256);

    function decimals() external view returns (uint256);
}

interface IRoles {
    function hasRole(bytes32 role, address account)
        external
        view
        returns (bool);

    function getHashRole(string calldata _roleName)
        external
        view
        returns (bytes32);

    function grantRole(bytes32 role, address beneficiary) external;
}

contract Recaudador is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    address public oracleAddress; // matic/usd
    address public TOKENADDRESS; // usdc
    address public MATIC; // WMATIC
    address public ROUTER; // QUICKSWAP ROUTER

    address public walletRecaudadora; //wallet recaudadora

    uint256 public maxNftAmount; // max nft to sell
    uint256 public nftSold; // nfts already sold
    uint256 public usdPrice; //precio del nft en weis
    uint256 public nftsRedeemed; //nfts reclamados
    uint256 public slippagePorcentual; //porcentage de slippage, el 100% es el valor 1000

    AggregatorV3Interface public priceFeed; //variable a la cual se le envian transacciones del oraculo
    UniswapV2Router02 public router; //variable a la cual se le envian transacciones del router
    IRoles public roles; //variable a la cual se le envian transacciones de roles

    //PATRON REGISTRO DE ADDRESS E INFORMACION *************
    //estructura que posee informacion sobre los nfts que un cliente compro y reclamo
    struct ClientInfo {
        uint256 nftsPresalePurchased;
        uint256 claimedNfts;
    }
    mapping(address => ClientInfo) private clientInfo; //mapping que registra los address con estructura
    address[] private clients; //array para tener registro de cantidad de clientes
    //******************** FIN PATRON

    //Evento para registrar informacion sobre el cliente, se emite despues de una compra
    event Purchase(
        address indexed wallet,
        uint256 nftAmount,
        uint256 usdcAmount,
        uint256 maticAmount
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    /* _priceOfNft: precio del nft en dolares expresado en Weis (18 decimales/ 10**18), 1 dolar = 1000000000000000000 weis
        _nftAmount: cantidad de nfts a la venta, se expresa en numeros enteros
        _roles: address del contrato de roles deployado por Dapps Factory
     */
    function initialize(
        address _walletRecaudadora,
        uint256 _nftAmount,
        uint256 _priceOfNft,
        address _roles
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init();
        __Pausable_init();
        require(_walletRecaudadora != address(0), "address 0");
        require(_priceOfNft > 0, "Price cannot be 0");
        require(_roles != address(0), "Roles cannot be address 0");
        usdPrice = _priceOfNft; // viene en wei => 1.47usd = 1470000000000000000usd
        priceFeed = AggregatorV3Interface(0xAB594600376Ec9fD91F8e885dADF0CE036862dE0);
        roles = IRoles(_roles);
        router = UniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
        walletRecaudadora = _walletRecaudadora;
        maxNftAmount = _nftAmount;
        oracleAddress = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0; // matic/usd
        TOKENADDRESS = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // usdc
        MATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // WMATIC
        ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; // QUICKSWAP ROUTER
        slippagePorcentual = 10; //el valor 10 significa el 1%, se calcula como slippagePorcentual/1000. 
    }

    //Funcion que los clientes llaman para realizar la compra de 1 nft
    function buy() external payable nonReentrant whenNotPaused {
        uint256 nftPrice = computeAmount();
        require(msg.value >= nftPrice, "Insufficient founds");
        require(nftSold + 1 <= maxNftAmount, "Insuficient Nfts for sell"); // lo que compra sumado a lo que se vendio tiene que ser menor al maximo
        if (clientInfo[msg.sender].nftsPresalePurchased == 0) {
            // Agrega por unica vez al array y da el rol una unica vez
            clients.push(msg.sender);
            roles.grantRole(keccak256("PRE_SALE_NFT_BUYER"), msg.sender);
        }
        clientInfo[msg.sender].nftsPresalePurchased++;
        nftSold++;
        uint256 amountUsdcTransfered = _swapTokens(msg.value); //se transfieren usdc a la wallet recaudadora
        emit Purchase(msg.sender, 1, amountUsdcTransfered, msg.value);
    }

    //Llamada externa al oraculo, devuelve el precio de 1 matic en usd. Cantidad de dolares que cuesta un matic expresado en 8 decimales
    function getLatestPrice() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    //Funcion que calcula el precio de 1 nft teniendo en cuenta el usdPrice y el precio del matic al momento de la compra
    //Retorna la cantidad de matics expresado en weis
    function computeAmount() public view returns (uint256) {
        return ((usdPrice * (10**8)) / getLatestPrice());
    }

    /* Funcion que cambia los matic que vale un NFT por USDC y los transfiere a la wallet Recaudadora 
    param:
        _nftPrice: valor de un Nft en matic expresado en weis
    global:
    usdPrice: precio de un NFT en dolares expresado en weis seteado inicialmente
     */
    function _swapTokens(uint256 _nftPrice) internal returns (uint256) {
        uint256 usdcAmount = usdPrice /10**12;//debemos convertir amountUsdcOutMin a 6 decimales para poder comparar con amounts[1] que es el monto que realmente sale
        // Amount with a % substracted
        uint256 amountUsdcOutMin = usdcAmount - ((usdcAmount * slippagePorcentual) / 1000); 
        //path for the router
        address[] memory path = new address[](2);
        path[1] = TOKENADDRESS; //usdc address
        path[0] = MATIC; //wMatic address
        //amount out is in 6 decimals
        uint256[] memory amounts = router.swapExactETHForTokens{value: _nftPrice}(amountUsdcOutMin, path, walletRecaudadora, block.timestamp);
        return amounts[1]; //monto que se transfiere
    }

    // funcion para retirar matic almacenados en el contrato
    function withdrawEmergency() external onlyOwner whenPaused {
        require(address(this).balance > 0, "Insuficient funds");
        (bool success, ) = walletRecaudadora.call{value: address(this).balance}("");
        require(success, "Forward funds fail");
    }

    //Funcion para establecer el precio del NFT, se setea el dolares expresado en weis
    function setPrice(uint256 _newAmount) external onlyOwner {
        require(_newAmount > 0, "New amount is 0");
        usdPrice = _newAmount;
    }

    //Funcion para settear el slippage, el 100% equivale al valor 1000.
    //Valor default=10, equivale a un slippage de 1%
    //Ejemplo: valor de 155 equivale a un porcentaje 15,5%
    function setSlippage(uint256 _newSlippage) external onlyOwner {
        require(_newSlippage > 0, "Slippage equal 0");
        slippagePorcentual = _newSlippage;
    }

    //Function para cambiar la wallet que recibe los pagos convertidos en USDC
    function setWalletRecaudadora(address _newWalletRecaudadora) external onlyOwner {
        require(_newWalletRecaudadora != address(0), "Address cannot be null address");
        walletRecaudadora = _newWalletRecaudadora;
    }

    //Funcion para cambiar la maxima cantidad de nfts a la venta
    function setMaxNftAmount(uint256 _newAmount) external onlyOwner {
        require(_newAmount > 0, "Amount is 0");
        maxNftAmount = _newAmount;
    }

    //Function para obtener el array de todos los clientes que hayan comprado
    function getClients() external view returns (address[] memory) {
        return clients;
    }

    //Funcion que solo puede ser llamada por el contrato de Mistery Box
    // Si no tiene nfts disponibles para reclamar retorna false, si puede reclamar un nft actualiza los contadores y devuelve true
    function canRedeem(address _beneficiary)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        require(
            roles.hasRole(
                roles.getHashRole("MISTERY_BOX_ADDRESS"),
                msg.sender
            ),
            "Sender must have mistery box role"
        );
        if (
            clientInfo[_beneficiary].nftsPresalePurchased ==
            clientInfo[_beneficiary].claimedNfts
        ) {
            return false;
        } else {
            clientInfo[_beneficiary].claimedNfts++;
            nftsRedeemed++;
            return true;
        }
    }

    //Funcion que devuelve la estructura de un cliente con la informacion sobre sus compras y reclamoss
    function getClientInfo(address _beneficiary)
        external
        view
        returns (ClientInfo memory)
    {
        return clientInfo[_beneficiary];
    }

    //Funcion que devuelve la diferencia entre los nfts que se compraron y los que se reclamaron
    //Devuelve los nfts que han sido comprados pero no reclamados
    function getNftsToRedeem() external view returns (uint256) {
        return nftSold - nftsRedeemed;
    }

    //Funcion para setear un nuevo contrato de roles
    function setRoles(address _newRoles) external onlyOwner whenPaused {
        require(_newRoles != address(0),"New Roles Address cannot be 0 address");
        roles = IRoles(_newRoles);
    }

    //Funcion para pausar
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    //Funcion para despausar
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-_authorizeUpgrade}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function _authorizeUpgrade(address _newImplementation)
        internal
        override
        whenPaused
        onlyOwner
    {}

    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeTo}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function upgradeTo(address _newImplementation)
        external
        override
        onlyOwner
        whenPaused
    {
        _authorizeUpgrade(_newImplementation);
        _upgradeToAndCallUUPS(_newImplementation, new bytes(0), false);
    }

    /**
     *
     * @dev See {utils/UUPSUpgradeable-upgradeToAndCall}.
     *
     * Requirements:
     *
     * - The caller must have ``role``'s admin role.
     * - The contract must be paused
     *
     */

    function upgradeToAndCall(address _newImplementation, bytes memory _data)
        external
        payable
        override
        onlyOwner
        whenPaused
    {
        _authorizeUpgrade(_newImplementation);
        _upgradeToAndCallUUPS(_newImplementation, _data, true);
    }
}
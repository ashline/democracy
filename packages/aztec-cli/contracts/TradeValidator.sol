pragma solidity >=0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";

import "./ParamUtils.sol";
import "./TradeUtils.sol";
import "./ZkAssetTradeable.sol";
import "./libs/NoteUtils.sol";
import "./ACE/ACE.sol";
import "./interfaces/IAZTEC.sol";

contract TradeValidator is IAZTEC {
    using NoteUtils for bytes;
    using SafeMath for uint256;

    uint256 public chainId;
    ACE public ace;

    bytes2 public constant MAGIC_BYTES = 0x1901;

    bytes32 public constant SALT = 0x655a1a74fefc4b03038d941491a1d60fc7fbd77cf347edea72ca51867fb5a3dc;

    string public constant TRADE_TYPE = "Trade(address sellerAddress,address bidderAddress,address sellerTokenAddress,address bidderTokenAddress,bytes32 sellerInputNoteHash,bytes32 bidderOutputNoteHash,bytes32 bidderInputNoteHash,bytes32 sellerOutputNoteHash,uint256 saleExpireBlockNumber,uint256 bidExpireBlockNumber)";
    bytes32 public constant TRADE_TYPEHASH = keccak256(abi.encodePacked(TRADE_TYPE));

    string public constant EIP712_DOMAIN = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)";
    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(abi.encodePacked(EIP712_DOMAIN));

    constructor(uint256 _chainId, address _aceAddress) public {
        chainId = _chainId;
        ace = ACE(_aceAddress);
    }

   function validateAndGetFirstProofOutput(
        bytes memory _proofData,
        address _proofSender
    ) public returns (bytes memory _proofOutput, bytes32 _proofHash) {
        bytes memory proofOutput = ace.validateProof(JOIN_SPLIT_PROOF, _proofSender, _proofData).get(0);
        return (proofOutput, keccak256(_proofOutput));
    }

    function validateProofByHash(
        bytes memory _proofOutput,
        address _signer
    ) public view returns (bool) {
        bytes32 proofHash = keccak256(_proofOutput);
        return ace.validateProofByHash(JOIN_SPLIT_PROOF, proofHash, _signer);
    }

    function extractFirstProofOutput(
        bytes memory _proofData,
        address _transferer
    ) public returns (
        bytes memory _inputNotes,
        bytes memory _outputNotes,
        address _owner,
        int256 _publicValue,
        bytes32 _proofHash
    ) {
        (bytes memory proofOutput, bytes32 proofHash) = validateAndGetFirstProofOutput(_proofData, _transferer);
        (bytes memory inputNotes, bytes memory outputNotes, address owner, int256 publicValue) = proofOutput.extractProofOutput();
        return (inputNotes, outputNotes, owner, publicValue, proofHash);
    }

    function extractAndVerifyNoteHashes(
        bytes memory _proofOutput,
        address _transferer
    ) public view returns (bytes32, bytes32) {

        bytes memory formattedProofOutput = ParamUtils.sliceBytes(_proofOutput, 32, _proofOutput.length);
        bytes32 proofHash = keccak256(formattedProofOutput);

        require( ace.validateProofByHash(
            JOIN_SPLIT_PROOF, proofHash, _transferer
            ), "proof output is invalid" );
        (bytes memory inputNotes, bytes memory outputNotes, ,)
            = formattedProofOutput.extractProofOutput();

        require(
            inputNotes.getLength()  >= 1,
            "Number of seller input notes is different than 1"
        );
        require(
           outputNotes.getLength() >= 2,
           "Number of seller output notes is different than 2"
        );
        (,bytes32 inputNoteHash,) = inputNotes.get(0).extractNote();
        (,bytes32 outputNoteHash,) = outputNotes.get(0).extractNote();

        return (inputNoteHash, outputNoteHash);
    }

    function extractAllNoteHashes(
        bytes memory _sellerProofOutput,
        bytes memory _bidderProofOutput,
        address transferer
    ) public view returns (bytes32, bytes32, bytes32, bytes32) {

        (bytes32 sellerInputNoteHash, bytes32 bidderOutputNoteHash)
            = extractAndVerifyNoteHashes(
                _sellerProofOutput,
                transferer
            );
        (bytes32 bidderInputNoteHash, bytes32 sellerOutputNoteHash)
            = extractAndVerifyNoteHashes(
                _bidderProofOutput,
                transferer
            );
        return (sellerInputNoteHash, bidderOutputNoteHash, bidderInputNoteHash, sellerOutputNoteHash);
    }

    function extractAndHashTrade(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutput,
        bytes memory _bidderProofOutput
    ) public view returns (bytes32) {

        address transferer = ParamUtils.getAddress(_sellerParams, 72); 

        (
            bytes32 sellerInputNoteHash,
            bytes32 bidderOutputNoteHash,
            bytes32 bidderInputNoteHash,
            bytes32 sellerOutputNoteHash
        ) = extractAllNoteHashes(
                _sellerProofOutput,
                _bidderProofOutput,
                transferer
            );

        return hashTrade(
          _sellerParams,
          _bidderParams,
          sellerInputNoteHash,
          bidderOutputNoteHash,
          bidderInputNoteHash,
          sellerOutputNoteHash
        );
    }

    // For testing only, for production we use extractAndHashTrade
    function extractAndHash(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutput,
        bytes memory _bidderProofOutput
    ) public view returns (bytes32) {

        address transferer = ParamUtils.getAddress(_sellerParams, 72); 

        (
            bytes32 sellerInputNoteHash,
            bytes32 bidderOutputNoteHash,
            bytes32 bidderInputNoteHash,
            bytes32 sellerOutputNoteHash
        ) = extractAllNoteHashes(
                _sellerProofOutput,
                _bidderProofOutput,
                transferer
            );

        return hashMessage(
          _sellerParams,
          _bidderParams,
          sellerInputNoteHash,
          bidderOutputNoteHash,
          bidderInputNoteHash,
          sellerOutputNoteHash
        );
    }

    function verifyTrade(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutput,
        bytes memory _bidderProofOutput
    ) public view returns (bool) {

        address recoveredSigner = extractAndRecover(
            _sellerParams,
            _bidderParams,
            _sellerProofOutput,
            _bidderProofOutput
        );

        address bidderAddress = ParamUtils.getAddress(_bidderParams, 0);
        return bidderAddress == recoveredSigner;
    }

    function extractAndRecover(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutput,
        bytes memory _bidderProofOutput
    ) public view returns (address) {

        bytes32 hash = extractAndHashTrade(
            _sellerParams,
            _bidderParams,
            _sellerProofOutput,
            _bidderProofOutput
        );

        bytes32 sigR = ParamUtils.getBytes32(_bidderParams, 72);
        bytes32 sigS = ParamUtils.getBytes32(_bidderParams, 104);
        uint8 sigV   = ParamUtils.getUint8(_bidderParams, 136);

        //address bidderAddress = ParamUtils.getAddress(_bidderParams, 0);
        return ecrecover(hash, sigV, sigR, sigS);
    }

    function getDomainSeparator() public view returns (bytes32 _domainSeparator) {
        return keccak256(abi.encodePacked(
            EIP712_DOMAIN_TYPEHASH,
            keccak256("Democracy.js Linked Trade Validator"),
            keccak256("1"),
            chainId,
            address(this),
            SALT
        ));
    }

    function hashMessage(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes32 _sellerInputNoteHash,
        bytes32 _bidderOutputNoteHash,
        bytes32 _bidderInputNoteHash,
        bytes32 _sellerOutputNoteHash
    ) public view returns (bytes32) {

        address sellerAddress         = ParamUtils.getAddress(_sellerParams, 0);
        address bidderAddress         = ParamUtils.getAddress(_bidderParams, 0);
        address sellerTokenAddress    = ParamUtils.getAddress(_sellerParams, 20);
        address bidderTokenAddress    = ParamUtils.getAddress(_bidderParams, 20);

        // uint256's begin at the end and count back 32 bytes to 40
        uint256 saleExpireBlockNumber = ParamUtils.getUint256(_sellerParams, 72);
        uint256 bidExpireBlockNumber  = ParamUtils.getUint256(_bidderParams, 72);

        require( saleExpireBlockNumber > block.number, "Sale expiration block number should be in the future." );
        require( bidExpireBlockNumber  > block.number, "Bid expiration block number should be in the future." );

      return keccak256(abi.encodePacked(
            TRADE_TYPEHASH,
            sellerAddress,
            bidderAddress,
            sellerTokenAddress,
            bidderTokenAddress,
            _sellerInputNoteHash,
            _bidderOutputNoteHash,
            _bidderInputNoteHash,
            _sellerOutputNoteHash,
            saleExpireBlockNumber,
            bidExpireBlockNumber
        ));
    }

    function hashTrade(
        bytes memory _bidderParams,
        bytes memory _sellerParams,
        bytes32 _sellerInputNoteHash,
        bytes32 _bidderOutputNoteHash,
        bytes32 _bidderInputNoteHash,
        bytes32 _sellerOutputNoteHash
    ) public view returns (bytes32) {

        return keccak256(abi.encodePacked(
            MAGIC_BYTES,
            getDomainSeparator(),
            hashMessage(
                _bidderParams,
                _sellerParams,
                _sellerInputNoteHash,
                _bidderOutputNoteHash,
                _bidderInputNoteHash,
                _sellerOutputNoteHash
            )
        ));
    }

    function verifyTradeFromProofOutputs(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutputs,
        bytes memory _bidderProofOutputs
    ) public view returns (bool) {
        bytes memory sellerProofOutput = TradeUtils.getFirstProofOutput(_sellerProofOutputs);
        bytes memory bidderProofOutput = TradeUtils.getFirstProofOutput(_bidderProofOutputs);

        // First check and fail early if trade is not valid
        return verifyTrade(
            _sellerParams,
            _bidderParams,
            sellerProofOutput,
            bidderProofOutput
        );

    }

    function linkedTransfer(
        bytes memory _sellerParams,
        bytes memory _bidderParams,
        bytes memory _sellerProofOutputs,
        bytes memory _bidderProofOutputs,
        bytes memory _sellerSignatures,
        bytes memory _bidderSignatures,
        bytes memory _sellerProofData,
        bytes memory _bidderProofData
    ) public {

        bool isValid = verifyTradeFromProofOutputs(
            _sellerParams,
            _bidderParams,
            _sellerProofOutputs,
            _bidderProofOutputs
        );
        require( isValid, "Invalid trade signature for bidder." );

        address transferer = ParamUtils.getAddress(_sellerParams, 72);
        address sellerTokenAddress = ParamUtils.getAddress(_sellerParams, 20);
        address bidderTokenAddress = ParamUtils.getAddress(_bidderParams, 20);
        ZkAssetTradeable sellerToken = ZkAssetTradeable(sellerTokenAddress);
        ZkAssetTradeable bidderToken = ZkAssetTradeable(bidderTokenAddress);
        sellerToken.confidentialTrade(
            _sellerProofOutputs,
            _sellerSignatures,
            _sellerProofData,
            transferer
        );
        bidderToken.confidentialTrade(
            _bidderProofOutputs,
            _bidderSignatures,
            _bidderProofData,
            transferer
        );
    }

}

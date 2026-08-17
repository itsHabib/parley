module Example
  ( protocolName,
    roles,
    validProtocol,
    invalidProtocol,
  )
where

import Protocol (Protocol (..), Role)

protocolName :: String
protocolName = "evidence-pipeline"

roles :: [Role]
roles = ["producer", "collector", "kernel", "human", "gate"]

-- The evidence-carrying-PR flow: producer submits a receipt, collector
-- triages it, kernel validates accepted receipts, a human judges gaps,
-- and gate acts only on an assurance pass or a recorded judgment.
validProtocol :: Protocol
validProtocol =
  Message "producer" "collector" "evidence.receipt" $
    Choice
      "collector"
      ["producer", "kernel", "human", "gate"]
      [ ( "accepted",
          Message "collector" "kernel" "validate" $
            Choice
              "kernel"
              ["collector", "human", "gate"]
              [ ("pass", Message "kernel" "gate" "assurance.pass" End),
                ( "gap",
                  Message "kernel" "human" "assurance.gap" $
                    Message "human" "gate" "judgment" End
                )
              ]
        ),
        ("malformed", Message "collector" "producer" "receipt.rejected" End)
      ]

-- Gate has different obligations in the accepted and malformed branches but
-- collector does not notify it. Projection must refuse this protocol.
invalidProtocol :: Protocol
invalidProtocol =
  Message "producer" "collector" "evidence.receipt" $
    Choice
      "collector"
      ["producer", "kernel", "human"]
      [ ("accepted", Message "kernel" "gate" "assurance.pass" End),
        ("malformed", End)
      ]

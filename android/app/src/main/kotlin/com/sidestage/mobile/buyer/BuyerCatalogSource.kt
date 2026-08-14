// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import uniffi.sidestage.CatalogPage
import uniffi.sidestage.CatalogSearch
import uniffi.sidestage.EventSummary
import uniffi.sidestage.SideStageClientInterface

/**
 * The narrow slice of the shared core the Buyer browse surface needs.
 *
 * The generated `SideStageClientInterface` carries the whole buyer API — cart,
 * checkout, bidding, realtime. Depending on this three-method port instead lets
 * the browse rules be tested against a fake with no native library loaded, and
 * keeps a browse screen from reaching for a checkout call by accident.
 */
interface BuyerCatalogSource {
    suspend fun events(): List<EventSummary>

    suspend fun catalog(search: CatalogSearch): CatalogPage

    suspend fun productTypes(): List<String>
}

/** The real source: the shared Rust core over the UniFFI boundary. */
class ClientBuyerCatalogSource(
    private val client: SideStageClientInterface,
) : BuyerCatalogSource {
    override suspend fun events(): List<EventSummary> = client.events()

    override suspend fun catalog(search: CatalogSearch): CatalogPage = client.catalog(search)

    override suspend fun productTypes(): List<String> = client.productTypes()
}

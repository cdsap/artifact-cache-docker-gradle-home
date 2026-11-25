package com.awesomeapp.identity

import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.junit.runners.JUnit4
import org.junit.Rule
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import kotlin.test.assertTrue
import kotlin.test.assertNotNull
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import com.awesomeapp.identity.*
import com.awesomeapp.identity.Repository4_5


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel4_1Test {
        private lateinit var repository0: Repository4_5

    private lateinit var viewModel: Viewmodel4_1

    @Before
    fun setup() {
       repository0 = Repository4_5(com.awesomeapp.identity.Api4_6())
        viewModel = Viewmodel4_1(
            repository0
        )
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}

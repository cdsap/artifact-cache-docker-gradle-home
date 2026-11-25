package com.awesomeapp.share

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
import com.awesomeapp.share.*
import com.awesomeapp.share.Repository16_5


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel16_1Test {
        private lateinit var repository0: Repository16_5

    private lateinit var viewModel: Viewmodel16_1

    @Before
    fun setup() {
       repository0 = Repository16_5(com.awesomeapp.share.Api16_6())
        viewModel = Viewmodel16_1(
            repository0
        )
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}
